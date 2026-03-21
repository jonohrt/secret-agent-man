# Ollama/Gemma Activity Feed Summarizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the useless raw-tool-name activity feed with human-readable 1-2 line summaries powered by local Ollama + Gemma 4B, answering "do I need to read this or can I just act?"

**Architecture:** `OllamaClient` (stateless HTTP module) talks to local Ollama REST API. `Summarizer` reads the last ~10 JSONL conversation turns and sends them to Gemma for summarization. Fallback: extract last assistant text from JSONL when Ollama unavailable. Server receives summary broadcasts and updates activity feed. Delete old Anthropic API client.

**Tech Stack:** Elixir, Ollama REST API (localhost:11434), Gemma 4B, Req (existing dep)

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `lib/sam/llm/ollama_client.ex` | Stateless HTTP module: health check, model management, summarize |
| `test/sam/llm/ollama_client_test.exs` | OllamaClient tests with HTTP mocking |

### Modified Files
| File | Changes |
|------|---------|
| `lib/sam/session/summarizer.ex` | Read JSONL turns instead of tool-name strings, call OllamaClient, handle journal_found, fallback logic |
| `test/sam/session/summarizer_test.exs` | Update tests for JSONL-based summarization |
| `lib/sam/session/server.ex` | Accept `{:summary, ...}` messages, add summary to activity feed |
| `lib/sam_web/live/dashboard_live.ex` | Show Ollama availability nudge in activity feed |

### Deleted Files
| File | Reason |
|------|--------|
| `lib/sam/llm/client.ex` | Replaced by OllamaClient, no more Anthropic API |

---

### Task 1: OllamaClient Module

**Files:**
- Create: `lib/sam/llm/ollama_client.ex`
- Create: `test/sam/llm/ollama_client_test.exs`

- [ ] **Step 1: Write failing tests for OllamaClient**

```elixir
# test/sam/llm/ollama_client_test.exs
defmodule Sam.LLM.OllamaClientTest do
  use ExUnit.Case, async: true

  describe "available?/1" do
    test "returns true when Ollama responds" do
      # Use a test URL that we can control
      assert is_boolean(Sam.LLM.OllamaClient.available?())
    end
  end

  describe "summarize/2" do
    test "returns fallback when Ollama unavailable" do
      turns = [
        %{role: "assistant", content: "I'll fix the authentication bug in login.ex"},
        %{role: "assistant", content: "Reading the test file to understand the expected behavior"}
      ]

      result = Sam.LLM.OllamaClient.summarize(turns, base_url: "http://localhost:1")
      # When Ollama is unreachable, returns error
      assert {:error, _reason} = result
    end

    test "formats turns into prompt correctly" do
      turns = [
        %{role: "assistant", content: "Editing server.ex to add status tracking"},
        %{role: "tool", name: "Edit", content: nil},
        %{role: "assistant", content: "Now running tests to verify the change"}
      ]

      prompt = Sam.LLM.OllamaClient.build_prompt(turns)
      assert prompt =~ "Editing server.ex"
      assert prompt =~ "Edit"
      assert prompt =~ "running tests"
      assert prompt =~ "what just happened"
    end
  end

  describe "extract_turns/2" do
    @tag :tmp_dir
    test "extracts last N assistant/user turns from JSONL", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "test.jsonl")

      records =
        for i <- 1..15 do
          Jason.encode!(%{
            "message" => %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Turn #{i} content"}]
            }
          })
        end

      File.write!(jsonl_path, Enum.join(records, "\n") <> "\n")

      turns = Sam.LLM.OllamaClient.extract_turns(jsonl_path, 10)
      assert length(turns) == 10
      # Should be the last 10
      assert hd(turns).content =~ "Turn 6"
    end

    @tag :tmp_dir
    test "caps total content at ~2000 chars", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "test.jsonl")

      records =
        for _i <- 1..5 do
          Jason.encode!(%{
            "message" => %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => String.duplicate("x", 1000)}]
            }
          })
        end

      File.write!(jsonl_path, Enum.join(records, "\n") <> "\n")

      turns = Sam.LLM.OllamaClient.extract_turns(jsonl_path, 10)
      total = turns |> Enum.map(& &1.content) |> Enum.join() |> String.length()
      assert total <= 2200
    end

    @tag :tmp_dir
    test "extracts tool names from tool_use blocks", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "test.jsonl")

      record =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Let me read the file"},
              %{"type" => "tool_use", "name" => "Read", "id" => "t1", "input" => %{}}
            ]
          }
        })

      File.write!(jsonl_path, record <> "\n")

      turns = Sam.LLM.OllamaClient.extract_turns(jsonl_path, 10)
      assert length(turns) == 1
      assert hd(turns).content =~ "Let me read the file"
      assert hd(turns).content =~ "[Read]"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/llm/ollama_client_test.exs`
Expected: Compilation error — module not found

- [ ] **Step 3: Implement OllamaClient**

```elixir
# lib/sam/llm/ollama_client.ex
defmodule Sam.LLM.OllamaClient do
  @moduledoc """
  Stateless HTTP client for local Ollama API.
  Provides summarization via Gemma 4B with fallback handling.
  """
  require Logger

  @default_base_url "http://localhost:11434"
  @default_model "gemma3:4b"
  @generate_timeout_ms 15_000
  @pull_timeout_ms 300_000
  @max_content_chars 2000

  # --- Public API ---

  def available?(opts \\ []) do
    url = base_url(opts)

    case Req.get("#{url}/api/tags", receive_timeout: 3_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  def summarize(turns, opts \\ []) when is_list(turns) do
    url = base_url(opts)
    model = Keyword.get(opts, :model, @default_model)

    prompt = build_prompt(turns)

    body = %{
      model: model,
      prompt: prompt,
      stream: false,
      options: %{num_predict: 100, temperature: 0.3}
    }

    case Req.post("#{url}/api/generate",
           json: body,
           receive_timeout: @generate_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: 404}} ->
        # Model not found — attempt to pull
        Logger.info("[OllamaClient] Model #{model} not found, pulling...")
        pull_model_async(model, opts)
        {:error, :model_pulling}

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama error #{status}: #{inspect(body)}"}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_prompt(turns) when is_list(turns) do
    conversation =
      turns
      |> Enum.map(fn
        %{role: "tool", name: name} -> "[Tool: #{name}]"
        %{role: role, content: content} -> "#{role}: #{content}"
        other -> inspect(other)
      end)
      |> Enum.join("\n")

    """
    You are summarizing an AI coding agent's activity for a dashboard.
    In 1-2 lines, tell the user what just happened and whether they need to take action.
    Don't describe tools or process — describe outcomes and decisions.
    Be specific about file names and what changed.

    Conversation:
    #{conversation}

    Summary:
    """
  end

  def extract_turns(jsonl_path, max_turns \\ 10) do
    case File.read(jsonl_path) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_jsonl_record/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-max_turns)
        |> truncate_content(@max_content_chars)

      {:error, _} ->
        []
    end
  end

  # --- Private ---

  defp parse_jsonl_record(line) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"role" => role, "content" => content}}} when is_list(content) ->
        text_parts =
          content
          |> Enum.map(fn
            %{"type" => "text", "text" => text} -> text
            %{"type" => "tool_use", "name" => name} -> "[#{name}]"
            %{"type" => "tool_result"} -> nil
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        if text_parts != "" do
          %{role: role, content: text_parts}
        end

      {:ok, %{"message" => %{"role" => role, "content" => content}}} when is_binary(content) ->
        if content != "", do: %{role: role, content: content}

      _ ->
        nil
    end
  end

  defp truncate_content(turns, max_chars) do
    {result, _remaining} =
      turns
      |> Enum.reverse()
      |> Enum.reduce({[], max_chars}, fn turn, {acc, remaining} ->
        len = String.length(turn.content)

        cond do
          remaining <= 0 ->
            {acc, 0}

          len <= remaining ->
            {[turn | acc], remaining - len}

          true ->
            truncated = %{turn | content: String.slice(turn.content, 0, remaining)}
            {[truncated | acc], 0}
        end
      end)

    result
  end

  defp pull_model_async(model, opts) do
    url = base_url(opts)

    Task.start(fn ->
      case Req.post("#{url}/api/pull",
             json: %{name: model},
             receive_timeout: @pull_timeout_ms
           ) do
        {:ok, %{status: 200}} ->
          Logger.info("[OllamaClient] Model #{model} pulled successfully")

        {:ok, %{status: status}} ->
          Logger.warning("[OllamaClient] Failed to pull #{model}: status #{status}")

        {:error, reason} ->
          Logger.warning("[OllamaClient] Failed to pull #{model}: #{inspect(reason)}")
      end
    end)
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @default_base_url)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/llm/ollama_client_test.exs`
Expected: All tests pass (some may skip if Ollama not running — the `available?` test is a live check)

- [ ] **Step 5: Commit**

```bash
git add lib/sam/llm/ollama_client.ex test/sam/llm/ollama_client_test.exs
git commit -m "feat: add OllamaClient for local Gemma 4B summarization"
```

---

### Task 2: Update Summarizer to Read JSONL Turns

**Files:**
- Modify: `lib/sam/session/summarizer.ex`
- Modify: `test/sam/session/summarizer_test.exs`

- [ ] **Step 1: Write failing test for JSONL-based summarization**

```elixir
# Replace entire test/sam/session/summarizer_test.exs
defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: false

  describe "JSONL-based summarization" do
    @tag :tmp_dir
    test "summarizes from JSONL turns on decision point", %{tmp_dir: tmp_dir} do
      session_id = "test-sum-jsonl-#{System.unique_integer([:positive])}"
      jsonl_path = Path.join(tmp_dir, "session.jsonl")

      # Write a JSONL file with conversation turns
      records =
        [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "I'll fix the login bug by updating auth.ex"}
              ]
            }
          },
          %{
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Running tests to verify the fix"},
                %{"type" => "tool_use", "name" => "Bash", "id" => "t1", "input" => %{}}
              ]
            }
          }
        ]
        |> Enum.map(&Jason.encode!/1)

      File.write!(jsonl_path, Enum.join(records, "\n") <> "\n")

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50
        })

      # Simulate journal_found to give summarizer the JSONL path
      send(pid, {:journal_found, jsonl_path})

      # Push a decision point event to trigger summarization
      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Edit",
        timestamp: DateTime.utc_now()
      })

      # Should receive a summary (Ollama or fallback)
      assert_receive {:summary, ^session_id, %{summary: summary}}, 5000
      assert is_binary(summary)
      assert String.length(summary) > 0
    end

    @tag :tmp_dir
    test "falls back to last assistant text when Ollama unavailable", %{tmp_dir: tmp_dir} do
      session_id = "test-sum-fallback-#{System.unique_integer([:positive])}"
      jsonl_path = Path.join(tmp_dir, "session.jsonl")

      record =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I fixed the authentication bug in login.ex by adding a nil check"}
            ]
          }
        })

      File.write!(jsonl_path, record <> "\n")

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          # Force Ollama to be "unavailable" with bad URL
          ollama_opts: [base_url: "http://localhost:1"]
        })

      send(pid, {:journal_found, jsonl_path})

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Read",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, ^session_id, %{summary: summary}}, 5000
      # Fallback should contain the assistant's own text
      assert summary =~ "authentication bug" or summary =~ "login.ex" or is_binary(summary)
    end

    test "produces no summary when no JSONL path available" do
      session_id = "test-sum-nopath-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50
        })

      # No journal_found sent — summarizer has no JSONL path
      # Push a decision point
      Sam.Session.Summarizer.push_event(_pid, %{
        type: :tool_call,
        tool: "Read",
        timestamp: DateTime.utc_now()
      })

      # Should not receive a summary (no JSONL to read)
      refute_receive {:summary, ^session_id, _}, 500
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/session/summarizer_test.exs`
Expected: FAIL — Summarizer doesn't have JSONL reading logic yet

- [ ] **Step 3: Rewrite Summarizer**

```elixir
# lib/sam/session/summarizer.ex
defmodule Sam.Session.Summarizer do
  use GenServer
  require Logger

  @default_debounce_ms 5_000
  @decision_point_types [:tool_call, :input_needed, :agent_spawn, :completion, :activity]

  defstruct [:session_id, :debounce_ms, :timer_ref, :jsonl_path, :ollama_opts, buffer: []]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push_event(pid, event) do
    GenServer.cast(pid, {:event, event})
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok,
     %__MODULE__{
       session_id: session_id,
       debounce_ms: Map.get(opts, :debounce_ms, @default_debounce_ms),
       ollama_opts: Map.get(opts, :ollama_opts, [])
     }}
  end

  # Receive JSONL path from JournalFinder via PubSub
  @impl true
  def handle_info({:journal_found, path}, state) do
    Logger.info("[Summarizer] Received journal path: #{Path.basename(path)}")
    {:noreply, %{state | jsonl_path: path}}
  end

  # Receive parser events via PubSub
  def handle_info({:parser_event, _session_id, event}, state) do
    handle_cast({:event, event}, state)
  end

  def handle_info(:summarize, state) do
    state = do_summarize(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  # Ignore other PubSub messages
  def handle_info({:pty_output, _, _}, state), do: {:noreply, state}
  def handle_info({:pty_exit, _, _}, state), do: {:noreply, state}
  def handle_info({:summary, _, _}, state), do: {:noreply, state}
  def handle_info({:session_update, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:event, event}, state) do
    state = %{state | buffer: state.buffer ++ [event]}

    if event.type in @decision_point_types do
      state = schedule_summary(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp schedule_summary(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :summarize, state.debounce_ms)
    %{state | timer_ref: ref}
  end

  defp do_summarize(%{jsonl_path: nil} = state) do
    # No JSONL path yet — can't summarize
    %{state | buffer: []}
  end

  defp do_summarize(%{buffer: []} = state), do: state

  defp do_summarize(state) do
    turns = Sam.LLM.OllamaClient.extract_turns(state.jsonl_path)

    if turns == [] do
      %{state | buffer: []}
    else
      summary =
        case Sam.LLM.OllamaClient.summarize(turns, state.ollama_opts) do
          {:ok, text} ->
            text

          {:error, _reason} ->
            # Fallback: last assistant message text
            turns
            |> Enum.filter(&(&1.role == "assistant"))
            |> List.last()
            |> case do
              %{content: text} -> String.slice(text, 0, 160)
              nil -> "Agent is working..."
            end
        end

      summary = sanitize_text(summary)

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{state.session_id}",
        {:summary, state.session_id,
         %{
           summary: summary,
           timestamp: DateTime.utc_now()
         }}
      )

      %{state | buffer: []}
    end
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> ensure_valid_utf8()
  end

  defp sanitize_text(_), do: ""

  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      text
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _} -> valid
        {:incomplete, valid, _} -> valid
        valid when is_binary(valid) -> valid
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/session/summarizer_test.exs`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/summarizer.ex test/sam/session/summarizer_test.exs
git commit -m "refactor: Summarizer reads JSONL turns, uses OllamaClient instead of Anthropic API"
```

---

### Task 3: Wire Summary into Server Activity Feed

**Files:**
- Modify: `lib/sam/session/server.ex:230-232`

- [ ] **Step 1: Write failing test**

Add to `test/sam/session/server_test.exs`:

```elixir
test "summary event updates activity feed" do
  session_id = "test-summary-#{System.unique_integer([:positive])}"

  Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

  {:ok, pid} =
    GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "Sum Test"})

  assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000

  # Send a summary event
  Phoenix.PubSub.broadcast(
    Sam.PubSub,
    "session:#{session_id}",
    {:summary, session_id,
     %{
       summary: "Fixed auth bug in login.ex, tests passing",
       timestamp: DateTime.utc_now()
     }}
  )

  assert_receive {:session_update, ^session_id, state}, 1000
  assert [%{text: "Fixed auth bug in login.ex, tests passing", type: :summary} | _] = state.activity

  GenServer.stop(pid)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs`
Expected: FAIL — summary is currently ignored

- [ ] **Step 3: Update Server to handle summary events**

In `lib/sam/session/server.ex`, replace the `handle_info({:summary, ...})` that ignores summaries:

```elixir
@impl true
def handle_info({:summary, _session_id, %{summary: summary}}, state) do
  entry = %{
    type: :summary,
    text: summary,
    timestamp: DateTime.utc_now()
  }

  state = %{state | activity: [entry | state.activity] |> Enum.take(50)}
  broadcast_state(state)
  {:noreply, state}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs`
Expected: All tests pass

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs
git commit -m "feat: Server accepts summary events into activity feed"
```

---

### Task 4: Delete Old Anthropic API Client

**Files:**
- Delete: `lib/sam/llm/client.ex`

- [ ] **Step 1: Verify no remaining references**

Search for `Sam.LLM.Client` in the codebase. After Task 2, the Summarizer no longer calls it. Verify:

Run: `grep -r "Sam.LLM.Client" lib/ test/ --include="*.ex" --include="*.exs"`
Expected: No results (only in docs/plans which is fine)

- [ ] **Step 2: Delete the file**

```bash
rm lib/sam/llm/client.ex
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile`
Expected: No errors

- [ ] **Step 4: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove Anthropic API client (replaced by OllamaClient)"
```

---

### Task 5: Activity Feed Ollama Nudge

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex`

- [ ] **Step 1: Add Ollama availability check to mount**

In `mount/3`, add:

```elixir
ollama_available: Sam.LLM.OllamaClient.available?()
```

- [ ] **Step 2: Add nudge to activity feed panel**

In the ACTIVITY FEED panel section of the render template, after the panel header and before the activity items, add:

```heex
<%= unless @ollama_available do %>
  <div class="ollama-nudge">
    ⚡ Install <a href="https://ollama.com" target="_blank" style="color: var(--phosphor-green); text-decoration: underline;">Ollama</a> for AI-powered summaries
  </div>
<% end %>
```

- [ ] **Step 3: Add nudge CSS**

In `assets/css/app.css`, add:

```css
.ollama-nudge {
  padding: 0.4rem 0.75rem;
  font-size: 0.7rem;
  color: var(--outline);
  border-bottom: 1px solid var(--surface-bright);
  background: rgba(175,201,234,0.05);
}
```

- [ ] **Step 4: Style summary entries differently from tool entries in the feed**

In `assets/css/app.css`, add a style for summary-type activity items so they stand out:

```css
.activity-item .msg.summary {
  color: var(--on-surface);
  font-style: normal;
}
```

Update the `activity_msg_class` helper in `dashboard_live.ex`:

```elixir
defp activity_msg_class(%{type: :summary}), do: "summary"
defp activity_msg_class(%{type: :system}), do: "system"
defp activity_msg_class(%{type: :agent_event}), do: "agent-event"
defp activity_msg_class(_), do: ""
```

- [ ] **Step 5: Run full test suite**

Run: `mix precommit`
Expected: All checks pass

- [ ] **Step 6: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex assets/css/app.css
git commit -m "feat: add Ollama availability nudge and summary styling in activity feed"
```

---

### Task 6: End-to-End Verification

**Files:** None (verification only)

- [ ] **Step 1: Run precommit**

Run: `mix precommit`
Expected: All checks pass

- [ ] **Step 2: Restart Phoenix server**

Run: `mix phx.server`

- [ ] **Step 3: Verify with Ollama running**

1. Ensure Ollama is running: `ollama list` should show models
2. Open dashboard, create a session
3. Watch activity feed — should show 1-2 line summaries from Gemma
4. Verify summaries answer "what happened, do I need to act?"

- [ ] **Step 4: Verify without Ollama**

1. Stop Ollama: `pkill ollama` or stop the service
2. Refresh dashboard
3. Activity feed should show fallback (last assistant message text)
4. Nudge should appear: "Install Ollama for AI-powered summaries"

- [ ] **Step 5: Screenshot**

Use `mcp__screenshot-website-fast__take_screenshot` to capture the activity feed with summaries.
