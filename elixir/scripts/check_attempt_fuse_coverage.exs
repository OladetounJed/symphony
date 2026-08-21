thresholds = %{
  "SymphonyElixir.GitHub.AttemptLedger" => 88.0,
  "SymphonyElixir.Orchestrator" => 70.0,
  "SymphonyElixir.AgentRunner" => 70.0,
  "SymphonyElixir.Codex.AppServer" => 75.0,
  "SymphonyElixir.Codex.DynamicTool" => 90.0
}

Enum.each(thresholds, fn {module, threshold} ->
  path = Path.expand("cover/Elixir.#{module}.html", File.cwd!())
  html = File.read!(path)
  covered = Regex.scan(~r/class="hits">[1-9][0-9]*<\/td>/, html) |> length()
  missed = Regex.scan(~r/<tr class="miss">/, html) |> length()
  total = covered + missed
  percentage = if total == 0, do: 0.0, else: covered * 100.0 / total

  IO.puts(
    "#{module} critical line coverage: #{:erlang.float_to_binary(percentage, decimals: 2)}% " <>
      "(required #{:erlang.float_to_binary(threshold, decimals: 2)}%)"
  )

  if percentage < threshold do
    raise "#{module} critical coverage fell below #{threshold}%"
  end
end)
