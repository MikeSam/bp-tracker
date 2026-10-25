# BPTracker

iOS app that logs blood pressure from a photo of a home monitor's display. It saves readings to Apple Health and shows charts, reminders and a PDF report.

## Reading the display

Vision locates the printed `SYS`, `DIA` and `PUL`/`PULSE` labels. The 7-segment digits beside each label are then decoded segment by segment (`BPTracker/Reader.swift`). The labels can be on either side of the digits. Any monitor with a dark-on-light LCD and those three labels stacked beside the numbers should work. A value that can't be read is left blank, never guessed.

## Supported monitors

These are verified by photos in `Checks/` (run the check below):

| Monitor | Type | SYS / DIA | Pulse | Photo |
|---|---|---|---|---|
| B.Well MED-55 | upper arm | ✅ | ✅ | `med55.png`, `med55-2.png`, `med55-3.jpg` |
| Omron HEM-7120 (same housing as M2 / 3 Series) | upper arm | ✅ | ✅ 1 of 3 photos | `omron-hem7120*.jpg` |
| Omron M3 | upper arm | ✅ | ✅ | `omron-m3.jpg` |
| Omron R6 | wrist | ✅ | ✅ | `omron-r6.jpg` |
| Sanitas (wrist) | wrist | ✅ | ✅ | `sanitas-wrist.jpg` |
| Microlife (Gentle+) | upper arm | ✅ | ❌ digit touches the slanted LCD edge | `microlife.jpg` |

In the Omron HEM-7120 photos where pulse isn't read, the pulse digits are in the shadow at the bottom edge of the LCD.

### Tested, not supported yet

| Monitor | Why |
|---|---|
| Beurer BM26, Medisana, Omron M3 (glare photo) | Strong glare washes out the segments. A photo taken at an angle to the light reads fine |
| NAIS wrist monitors | Pulse label is `P/min` |
| Omron HEM-7000 (Asian market) | Chinese labels |
| Backlit displays (light digits on dark), LED displays (InBody, Welch Allyn) | Reader expects dark segments on a light LCD |
| Small or low-resolution photos | Vision can't find the labels |

### Popular monitors, not tested

These come from the 2026 best-seller and review lists ([AARP](https://www.aarp.org/health/conditions-treatments/best-blood-pressure-monitors/), [Cleveland Heart](https://clevelandheart.com/best-blood-pressure-monitors), [radcity](https://radcity.net/best-home-blood-pressure-monitors-2026/)):

- **Omron 3 / 5 / 7 / 10 Series, Platinum**: same LCD layout as the supported Omrons. Expected to work.
- **A&D UA-651 / Premium**: SYS/DIA/PUL labelled LCD. Expected to work, but no test photo yet.
- **Beurer BM57**, **iHealth Track**: labelled LCD. Untested.
- **Withings BPM Connect / Core**: values on an LED matrix with no labels. Not supported. These sync to Health on their own.

Monitor names are used only to describe compatibility. B.Well, Omron, Microlife, Sanitas and the other brands named here are trademarks of their respective owners. This project isn't affiliated with or endorsed by them.

To add a monitor, put a sharp, glare-free photo in `Checks/`, add its expected values to `fixtures` in `Checks/main.swift`, and run the check.

## Checks

```sh
swiftc -target arm64-apple-macos15.0 BPTracker/Reader.swift BPTracker/TrendView.swift BPTracker/Health.swift Checks/main.swift -o /tmp/reader_check && /tmp/reader_check
/tmp/reader_check photo.jpg   # print what the reader sees in any photo
```

## Photo credits

The `med55*` photos are our own. The other photos come from Wikimedia Commons:

| File | Author | License | Source |
|---|---|---|---|
| `omron-hem7120.jpg` | Amit article21 | CC BY-SA 4.0 | [Souravdeep.jpg](https://commons.wikimedia.org/wiki/File:Souravdeep.jpg) |
| `omron-hem7120-2.jpg` | Henrique Lincon | CC0 | [Imagem pressao 5.jpg](https://commons.wikimedia.org/wiki/File:Imagem_pressao_5.jpg) |
| `omron-hem7120-3.jpg` | Henrique Lincon | CC0 | [Imagem pressao 4.jpg](https://commons.wikimedia.org/wiki/File:Imagem_pressao_4.jpg) |
| `omron-m3.jpg` | Dmitry G | CC BY-SA 3.0 | [Display of Omron M3 20151122.jpg](https://commons.wikimedia.org/wiki/File:Display_of_Omron_M3_20151122.jpg) |
| `omron-r6.jpg` | Amirhossein Ashrafzadeh | CC BY-SA 4.0 | [Blood Pressure & Heart Rate on Omron R6 20150222.jpg](https://commons.wikimedia.org/wiki/File:Blood_Pressure_%26_Heart_Rate_on_Omron_R6_20150222.jpg) |
| `sanitas-wrist.jpg` | Jacek Halicki | CC BY-SA 4.0 | [2017 Sfigmomanometr elektroniczny.jpg](https://commons.wikimedia.org/wiki/File:2017_Sfigmomanometr_elektroniczny.jpg) |
| `microlife.jpg` | Jacek Halicki | CC BY-SA 4.0 | [2020 Sfigmomanometr elektroniczny.jpg](https://commons.wikimedia.org/wiki/File:2020_Sfigmomanometr_elektroniczny.jpg) |
