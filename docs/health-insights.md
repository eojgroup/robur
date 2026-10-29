# On-device Health insights (1.1)

Robur reads approved HealthKit records and computes the following locally.
Missing or denied categories stay empty; changing shared history can change scores.
No Health values are uploaded and Robur does not write Health workouts.

| Feature | Behavior |
| --- | --- |
| Apple effort | iOS 18+ workout/effort relationships supply the actual Apple Fitness score. Imported effort takes precedence. HR-based intensity and personal ratings are labeled fallbacks. |
| Readiness | Sleep, HRV and resting HR compared with the prior 30-day personal baseline; recent activity and relative workload add context. At least two recovery signals with enough prior readings are required. |
| Training load | Duration × Apple effort, or estimated HR intensity when absent. 7/28-day totals and a relative load ratio are planning heuristics, not injury predictions. |
| Health trends | Available 7/30/90-day averages; sustained direction requires repeated observations, not one outlier. |
| Fitness score | Transparent cardio/activity/recovery/consistency/strength participation components; missing components are excluded and weights normalized. The methodology is visible in the app. |
| Workout analysis | Duration, distance, active calories, average HR, pace, sampled HR zones/timeline, available cadence, estimated distance-sample splits and comparable recent sessions. |
| Records | Best available complete comparable-distance workouts, longest session, most steps, highest VO2 max and lowest resting HR. Full-workout records are not presented as exact unmeasured 1/5/10-km segments. |
| Weekly report | Last seven complete days compared with the prior seven, with explicit coverage requirements. |
| Zones | Configurable max HR; optional age estimate 208 − 0.7 × age. Sample gaps are excluded, with recent-week/month and per-workout views. |
| Heatmap/streaks | Daily activity against configurable targets. Unshared days are not fabricated. |
| Adaptive goals | Suggest modest changes from recent activity; the user must confirm before applying them. |

Weight, height, BMI, body-fat percentage, respiratory rate, blood oxygen and
supported Health characteristics are optional. Full Medical ID, emergency
contacts and clinical records are not available through this integration.
Stand time means Apple Stand Time minutes, not stand-ring hours.

Daily readiness and weekly review reminders, scheduled movement breaks, and
refresh-time goal/trend alerts are opt-in local notifications. Reminder content
avoids health values on the lock screen. Goal/trend alerts are evaluated when
Health data refreshes, not by a continuously running background health monitor.
The app refreshes on foreground return when its snapshot is older than 15 minutes.

## Device acceptance

1. Review new Health categories; share Apple effort, steps/exercise/stand time,
   body measurements and enough history. Verify old and newly recorded workouts.
2. Compare imported effort with Fitness. Verify an effort-free workout retains
   a labeled fallback and a denied category never hides other approved history.
3. Compare daily activity totals with Health/Fitness, especially multiple data
   sources, sleep intervals crossing midnight and days with zero activity.
4. Inspect readiness/fitness methodology, charts and baseline coverage. Compare
   records, zone durations and estimated splits with source data.
5. Test proposed goal changes: Cancel must preserve the old goal; Apply updates it.
6. Enable/disable each reminder; test denied permission and timezone changes.
   Verify no repeated same-day goal alerts and no personal values on the lock screen.
7. Check large text, VoiceOver, iPad, light/dark appearance and the new icon on
   iPhone/Watch. The simulator uses explicit synthetic presentation fixtures only.
