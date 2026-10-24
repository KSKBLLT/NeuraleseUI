$lines = [System.IO.File]::ReadAllLines("scripts/simulations/simulation_brain_mapping_panel.gd")
$part1 = $lines[0..169] -join "`n"
$part2 = [System.IO.File]::ReadAllText("scratch/new_part.gd")
$final = $part1 + "`n" + $part2
$utf8NoBom = New-Object System.Text.UTF8Encoding $False
[System.IO.File]::WriteAllText("scripts/simulations/simulation_brain_mapping_panel.gd", $final, $utf8NoBom)
