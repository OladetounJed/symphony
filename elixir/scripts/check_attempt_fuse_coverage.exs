path = Path.expand("cover/Elixir.SymphonyElixir.GitHub.AttemptLedger.html", File.cwd!())
threshold = 88.0

html = File.read!(path)
covered = Regex.scan(~r/class="hits">[1-9][0-9]*<\/td>/, html) |> length()
missed = Regex.scan(~r/<tr class="miss">/, html) |> length()
total = covered + missed
percentage = if total == 0, do: 0.0, else: covered * 100.0 / total

IO.puts(
  "AttemptLedger critical line coverage: #{:erlang.float_to_binary(percentage, decimals: 2)}% " <>
    "(required #{:erlang.float_to_binary(threshold, decimals: 2)}%)"
)

if percentage < threshold do
  raise "AttemptLedger critical coverage fell below #{threshold}%"
end
