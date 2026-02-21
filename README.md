# Meshtastic ADC Multiplier Calibrator (Battery Voltage @ 100%)

A friendly, verbose Bash script that:
- creates/uses `~/Code/meshtastic`
- creates/uses a Python venv in that folder
- installs the `meshtastic` Python CLI into that venv
- waits for a Meshtastic device on `/dev/ttyACM0`
- reads `power.adc_multiplier_override`
- asks what voltage your device *displays* at **100% charge**
- calculates a corrected multiplier so that **100% corresponds to 4.2V**
- sets the new multiplier, reboots the device
- deactivates the venv right after the reboot command is issued

> **Calibration model used:** at **100% charge**, a 1S Li-ion/LiPo cell should be **4.2V**.  
> The script assumes your displayed battery voltage scales linearly with `power.adc_multiplier_override`.

---

## Why this exists

Some boards report battery voltage slightly off due to different resistor dividers / ADC scaling. Meshtastic exposes a multiplier override:
- `power.adc_multiplier_override`

This script helps you correct it so your device reads **4.2V** when it is truly **fully charged (100%)**.

---

## How the math works

If:
- `M_current` = current multiplier (override or your known effective baseline)
- `V_displayed_full` = voltage the device displays when it’s at 100%
- `V_target_full` = 4.2V

Then:

