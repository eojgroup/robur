# Recovery and fitness methodology 2.1

Robur computes a descriptive 0–100 wellness estimate, not a validated clinical
readiness test or an injury prediction. There is no industry-standard universal
conversion from these HealthKit inputs to one recovery score. The model borrows
monitoring practices from the [training-load consensus](https://pubmed.ncbi.nlm.nih.gov/28463642/)
and [AIS heart-rate variability guidance](https://www.ausport.gov.au/ais/position_statements/heart-rate-variability).
Apple reports [SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn),
which must not be interpreted as RMSSD. Sleep, measurement conditions, illness and
non-training stress can affect the observations.

Recovery combines HRV (25%), resting HR (20%), respiratory rate (10%), sleep
duration (25%), observed recent sleep shortfall (10%) and training demand (10%).
At least two direct physiological/sleep signals with adequate personal history
are required. Missing components are excluded and the remaining weights are
renormalized. The UI shows actual values, personal baselines, effective weights,
point contributions and coverage. Coverage measures available inputs, not medical
certainty. Sleep shortfall uses recorded nights; a missing night is not zero sleep.

Session load prioritizes duration multiplied by imported Apple effort, then
explicitly labelled available fallbacks. Seven- and 42-day exponentially smoothed
loads describe observed demand; these time constants and score weights are Robur
choices. They do not establish safe/unsafe load or injury thresholds. The complete
approved workout history seeds the load calculation independently of chart range.

Fitness excludes acute recovery. Its components are cardio (35%), movement (25%),
consistency (25%) and strength participation (15%). Cardio compares recent VO₂ max
with a reference queried from the first 28 calendar days of approved VO₂ max data,
requiring at least two readings and the completed reference window. Changing the
display range does not replace this reference. Strength measures participation,
not measured strength or muscle mass. Imported corrections, new permissions and
goal changes may revise recalculated history; versioned components remain visible.

Historical points use only observations available by their daily cutoff. The
app, graph details and optional export use the same engine and methodology version.
Widget "recovery signals" estimates have fewer inputs and are labelled separately.

Cloud deployment and native uploads are paused. Backend code is prepared for
private account-scoped records and explicit, revocable consent. No Google
infrastructure is deployed by validation or by an ordinary source push.
