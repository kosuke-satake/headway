# Feed analysis

Samples: 445, 2026-10-03 17:43:10 +0000 to 2026-10-04 22:07:22 +0000. Schedule S072_202608240858.

A sample is one minute. Counts below are summed over samples (trip-minutes / bus-minutes).

## 1. Scheduled trips without a reported position

| | trip-minutes | share |
|---|---:|---:|
| scheduled and in progress | 11935 | 100% |
| with a bus position | 11614 | 97.3% |
| no position, but a bus is assigned in the predictions | 1 | 0.0% |
| no position and no assigned bus | 320 | 2.7% |

### By route

| route | trip-minutes | without position |
|---|---:|---:|
| S | 185 | 16.8% |
| 81 | 133 | 12.8% |
| B | 1605 | 8.3% |
| 80 | 492 | 4.1% |
| L | 652 | 3.8% |
| P | 86 | 3.5% |
| R | 532 | 3.4% |
| 82 | 120 | 2.5% |
| E | 428 | 2.1% |
| A | 2072 | 2.1% |
| O | 177 | 1.7% |
| J | 310 | 0.6% |
| D | 1553 | 0.5% |
| H | 805 | 0.4% |
| F | 617 | 0.2% |
| C | 1004 | 0.1% |
| G | 1164 | 0.1% |

## 2. Buses reporting positions

| | bus-minutes | share |
|---|---:|---:|
| all buses in the position feed | 17409 | 100% |
| no trip id | 1204 | 6.9% |
| trip id unknown to the schedule | 0 | 0.0% |
| trip starts within 15 min (waiting at the terminal) | 673 | 3.9% |
| trip ended within 15 min | 2439 | 14.0% |
| trip far from its scheduled time | 1465 | 8.4% |

## 3. Position staleness (position time vs feed time)

- older than 60 s: 1.4%
- older than 120 s: 1.3%

## 4. Predicted arrival at the next stop vs timetable

Positive means later than the timetable. 11612 observations.

| percentile | seconds |
|---|---:|
| p5 | -108 |
| p25 | 9 |
| p50 | 101 |
| p75 | 240 |
| p95 | 546 |

- more than 5 min late: 18.3%
- more than 5 min early: 0.3%

# Are the live predictions better than the timetable?

449 trip-update snapshots compared with arrivals observed from bus positions. Error = predicted (or scheduled) time minus observed time, in seconds; positive means the prediction was later than reality.

| horizon | n | live: bias | live: median abs | live: p90 abs | timetable: bias | timetable: median abs | timetable: p90 abs |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0-2 min ahead | 16226 | 4 | 21 | 74 | -92 | 117 | 442 |
| 2-5 min | 24682 | 2 | 42 | 132 | -98 | 119 | 444 |
| 5-10 min | 40408 | -4 | 65 | 195 | -99 | 121 | 444 |
| 10-20 min | 78611 | -22 | 93 | 272 | -102 | 122 | 446 |
| 20-30 min | 71112 | -57 | 111 | 340 | -113 | 129 | 462 |

