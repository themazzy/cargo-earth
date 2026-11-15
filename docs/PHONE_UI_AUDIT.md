# Phone UI source audit

The actual Angular directive and its template were audited after the v0.10.0 bus fixes. Automated checks cover structural action placement and screen ownership. This is not a rendered or in-game visual sign-off.

| Screen or section | Controls kept outside scrolling details | Content that scrolls |
| --- | --- | --- |
| Not loaded / error | Work, Radio and Menu navigation | Long error explanations |
| Resume | Load latest save | Saved-car details and errors |
| Parts-preview interruption | Review parts | Explanation |
| First run | Start my career, Just drive | Career features and free-play explanation |
| Offline food work | Go online, work-mode selector | Status explanation |
| Offline freight | Go online when available, All contracts, work-mode selector | Nearby contract cards, including each offer's Route and Start |
| Bus discovery | Retry search, Cancel selection, work-mode selector | Route offers, depot information, progress/error details |
| Bus preparing / return | End shift when allowed | Preparation and handover status |
| Waiting for work | Go offline | Helper/status explanations |
| Incoming offer | Accept/Add order, Decline | Stops, items, cargo rules and bonuses |
| Active food, parcels, taxi or freight | Navigate, Cancel or company-contract access, online/offline control when allowed | Destination, route, items and condition details |
| Active towing | Hitch, Load or Restore when applicable, Navigate and cancellation | Wreck, trailer and handling information |
| Active bus route | Open doors or boarding countdown, Navigate, Skip stop, End shift | Stops and passenger details |
| Failed / completed order | Dismiss/Done | Receipt, ratings, records, damage and debt details |
| Company work screen | Open the contract | Company name |
| Radio | Play/Stop, Previous/Next and volume | Stations, favourites, stream options and errors |
| Menu: Home and Companies | Menu close; selected address Route/Make home; Route home; active company's Collect wages, Route and End early | Home search/results and contract offers |
| Menu: Garage | Menu close; My car/My cars/Used cars navigation; Start career; repair, roadside help and Parts shop; selected preview purchase/return; parts checkout confirm/discard/back | Car details, missing parts, parts list, listings, owned cars and drivers |
| Menu: Progress, Finances, Delivery map and Firm | Menu close and live-work shortcut | Records, ledger, map, firm requirements and management cards |
| Menu: Settings | Menu close and live-work shortcut | Preferences, support report, restart confirmation and dashboard adjustments |
| Headquarters | Close; separate scrollable plan | Buildings, bays, vehicles, applicants and upgrades |

Offer/list-specific actions stay on their respective cards. It is not possible to show every offer or every preference simultaneously on a 290 x 560 phone. Current-job and confirmation controls must not depend on how far their details have been scrolled.

## Layout safeguards

- Fixed action bars do not shrink with the details list. Incoming offer actions, navigation and the phone's status header also do not shrink.
- Long receipt/error content uses a bounded internal scroller with top alignment, avoiding content clipped above a vertically centred block.
- Notification banners share a bounded scroller, so a long save error cannot displace the job controls and phone navigation.
- Freight's summary is bounded; contracts use the available list space. All contracts is always outside the list.
- Action rows can wrap. Long names, amounts and menu headings can wrap; incoming quotes use a smaller font beside their countdown.
- Fuel, cargo and damage indicators wrap instead of silently truncating at the right edge.
- The radio station title is limited to two lines with the full title available on hover; playback controls remain visible while browsing stations.
- Menu contents have minimum height zero inside the dialog, and Close does not shrink. Narrow menu navigation has a bounded height.
- The headquarters plan switches to one vertically scrolling column below a 700 px viewport width.

## Verification and limits

The phone-layout test parses the generated directive template, inventories all 11 work states and every menu section, checks 40 critical action groups for scroll ancestors, and checks that moved work controls remain owned by the correct screen. Existing phone interaction, polling, template-nesting and Unicode tests still run.

Rendered verification at 290 x 560, 240 x 420 and 360 x 640 remains pending. BeamNG was closed during this audit, and browser policy blocked the local-file preview. No screenshot or pixel-perfect verification is claimed. After installing, check long names/prices, a long save error, bus boarding, tow pickup, parts checkout and purchase preview at those sizes.
