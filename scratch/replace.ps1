$target = "scripts/simulations/simulation_brain_mapping_panel.gd"
$lines = Get-Content $target | Select-Object -First 170
Set-Content $target $lines -Encoding UTF8
$new_part = Get-Content "scratch/new_part.gd" -Raw
Add-Content $target $new_part -NoNewline -Encoding UTF8
