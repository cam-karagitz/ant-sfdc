# Eval photos from Wikimedia Commons

Used only for measuring where Claude places damage boxes (`scripts/eval/boxes`). They are not static
resources and are not attached to any claim. Each was downloaded on Oct 4, 2026 and resized so its long
edge is at most 1,280 pixels, as the sample photos are; nothing else was changed.

| File | What it shows | Author | License | Source |
|---|---|---|---|---|
| `crackedWindshield.jpg` | A cracked windshield from inside the car | B.H. Dhiaeddine | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0) | [File:A cracked windshield.jpg](https://commons.wikimedia.org/wiki/File:A_cracked_windshield.jpg) |
| `vauxhall.jpg` | 1963 Vauxhall Velox with a dented door | Riley from Christchurch, New Zealand | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0) | [File:1963 Vauxhall Velox 3.3 (PB) (26736818753).jpg](https://commons.wikimedia.org/wiki/File:1963_Vauxhall_Velox_3.3_(PB)_(26736818753).jpg) |
| `cleanSedan.jpg` | A parked Toyota Century with no damage | Ominae | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0) | [File:Parked Toyota Century side view.jpg](https://commons.wikimedia.org/wiki/File:Parked_Toyota_Century_side_view.jpg) |
| `cleanRoom.jpg` | A living room and kitchen with no damage | Riverview Homes, Inc. | [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0) | [File:Kitchen and Living Room Singlewide.jpg](https://commons.wikimedia.org/wiki/File:Kitchen_and_Living_Room_Singlewide.jpg) |

The other eight photos in `cases.json` are the sample damage photos already in
`force-app/main/default/staticresources`, whose sources are in
`staticresources/antsuranceDamageSources/LICENSES.md`.

Any contact sheet built from these photos carries the same licenses; keep this file with them if they are shared.
