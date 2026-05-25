# Restriction Operators Explanation

This document explains how each restriction operator works for both **time** and **date** types.

---

## 📅 DATE RESTRICTIONS

### 1. **`is-between`** (Date Range)

**Values Required:** 2 dates `[startDate, endDate]`

**Logic:**

- Plays if current date is **between** start date and end date (inclusive)
- Includes the entire end date (adds 1 day to end date for inclusive check)

**Example:**

```json
{
  "type": "date",
  "operator": "is-between",
  "values": ["2026-01-01", "2026-01-31"]
}
```

- ✅ Plays from Jan 1 to Jan 31 (inclusive)
- ❌ Does NOT play on Dec 31 or Feb 1

**Code Logic:**

```dart
final endDateInclusive = endDate.add(const Duration(days: 1));
return now.isAfter(startDate) && now.isBefore(endDateInclusive);
```

---

### 2. **`on`** (Exact Date)

**Values Required:** 1 date `[targetDate]`

**Logic:**

- Plays when the exact date is reached, then **continues indefinitely**
- Current date must be **>= target date** (at or after the target date)

**Example:**

```json
{
  "type": "date",
  "operator": "on",
  "values": ["2026-01-15"]
}
```

- ❌ Does NOT play on Jan 14
- ✅ Plays on Jan 15 (starts)
- ✅ Continues playing on Jan 16, Jan 17, etc. (continues indefinitely)

**Code Logic:**

```dart
final shouldPlay = nowDateOnly.isAfter(targetDateOnly) ||
                   nowDateOnly.isAtSameMomentAs(targetDateOnly);
```

---

### 3. **`is-before`** (Before Date)

**Values Required:** 1 date `[targetDate]`

**Logic:**

- Plays **before** the target date
- **Stops** when the target date is reached

**Example:**

```json
{
  "type": "date",
  "operator": "is-before",
  "values": ["2026-01-15"]
}
```

- ✅ Plays on Jan 14, Jan 13, etc. (before target)
- ❌ Does NOT play on Jan 15 or after

**Code Logic:**

```dart
return now.isBefore(targetDate);
```

---

### 4. **`is-after`** (After Date)

**Values Required:** 1 date `[targetDate]`

**Logic:**

- Plays **after** the target date is reached, then **continues indefinitely**
- Includes the target date itself

**Example:**

```json
{
  "type": "date",
  "operator": "is-after",
  "values": ["2026-01-15"]
}
```

- ❌ Does NOT play on Jan 14
- ✅ Plays on Jan 15 (includes target date)
- ✅ Continues playing on Jan 16, Jan 17, etc. (continues indefinitely)

**Code Logic:**

```dart
return now.isAfter(targetDate) ||
       (now.year == targetDate.year &&
        now.month == targetDate.month &&
        now.day == targetDate.day);
```

---

### 5. **`not-on`** (Not On Date)

**Values Required:** 1 date `[targetDate]`

**Logic:**

- Plays **all the time EXCEPT** on the target date
- **Stops** on the target date

**Example:**

```json
{
  "type": "date",
  "operator": "not-on",
  "values": ["2026-01-15"]
}
```

- ✅ Plays on Jan 14, Jan 16, Jan 17, etc. (all other dates)
- ❌ Does NOT play on Jan 15 (target date)

**Code Logic:**

```dart
return !(nowDateOnly.isAtSameMomentAs(targetDateOnly));
```

---

## ⏰ TIME RESTRICTIONS

### 1. **`is-between`** (Time Range)

**Values Required:** 2 times `[startTime, endTime]` (format: "HH:mm" or "HH:mm:ss")

**Logic:**

- Plays if current time is **between** start time and end time (inclusive)
- Checks only hours and minutes (ignores seconds)

**Example:**

```json
{
  "type": "time",
  "operator": "is-between",
  "values": ["09:00", "17:00"]
}
```

- ❌ Does NOT play at 08:59 or 17:01
- ✅ Plays from 09:00 to 17:00 (inclusive)

**Code Logic:**

```dart
final result = currentTime.isAfter(startTime) &&
               currentTime.isBefore(endTime) ||
               currentTime.isAtSameMomentAs(startTime) ||
               currentTime.isAtSameMomentAs(endTime);
```

---

### 2. **`on`** (Exact Time)

**Values Required:** 1 time `[targetTime]` (format: "HH:mm" or "HH:mm:ss")

**Logic:**

- Plays **ONLY** at the exact time (same hour and minute)
- **Stops** at the next minute

**Example:**

```json
{
  "type": "time",
  "operator": "on",
  "values": ["04:48"]
}
```

- ❌ Does NOT play at 04:47
- ✅ Plays at 04:48 (exact match)
- ❌ Does NOT play at 04:49 (stops at next minute)
- ❌ Does NOT play at 17:14 (not the exact time)

**Code Logic:**

```dart
final shouldPlay = currentHour == targetHour &&
                   currentMinute == targetMinute;
```

---

### 3. **`is-before`** (Before Time)

**Values Required:** 1 time `[targetTime]` (format: "HH:mm" or "HH:mm:ss")

**Logic:**

- Plays **before** the target time
- **Stops** when the target time is reached

**Example:**

```json
{
  "type": "time",
  "operator": "is-before",
  "values": ["19:05"]
}
```

- ✅ Plays at 19:04, 19:03, etc. (before target)
- ❌ Does NOT play at 19:05 or after

**Code Logic:**

```dart
return currentTime.isBefore(targetTime);
```

---

### 4. **`is-after`** (After Time)

**Values Required:** 1 time `[targetTime]` (format: "HH:mm" or "HH:mm:ss")

**Logic:**

- Plays **after** the target time is reached, then **continues indefinitely**
- Includes the target time itself
- Continues playing until the next day, then repeats

**Example:**

```json
{
  "type": "time",
  "operator": "is-after",
  "values": ["07:04"]
}
```

- ❌ Does NOT play at 07:03
- ✅ Plays at 07:04 (includes target time)
- ✅ Continues playing at 07:05, 08:00, 16:59, etc. (continues)
- ❌ Stops at 00:00 (midnight)
- ✅ Resumes at 07:04 the next day

**Code Logic:**

```dart
return currentTime.isAfter(targetTime) ||
       currentTime.isAtSameMomentAs(targetTime);
```

---

### 5. **`not-on`** (Not On Time)

**Values Required:** 1 time `[targetTime]` (format: "HH:mm" or "HH:mm:ss")

**Logic:**

- Plays **all the time EXCEPT** at the target time
- **Stops** at the target time

**Example:**

```json
{
  "type": "time",
  "operator": "not-on",
  "values": ["07:04"]
}
```

- ✅ Plays at 07:03, 07:05, 08:00, etc. (all other times)
- ❌ Does NOT play at 07:04 (target time)

**Code Logic:**

```dart
return !(currentTime.isAtSameMomentAs(targetTime));
```

---

## 🔄 HOW RESTRICTIONS WORK TOGETHER

### Multiple Restrictions (AND Logic)

If you have multiple restrictions, **ALL** must pass for the campaign/media to play:

```json
{
  "restrictions": [
    {
      "type": "time",
      "operator": "is-after",
      "values": ["09:00"]
    },
    {
      "type": "time",
      "operator": "is-before",
      "values": ["17:00"]
    }
  ]
}
```

This means: Play **after 09:00** AND **before 17:00** (essentially `is-between`)

---

## 📝 NOTES

1. **Time Format:** Times should be in "HH:mm" or "HH:mm:ss" format (24-hour)

   - ✅ Valid: "07:04", "19:30", "09:00:00"
   - ❌ Invalid: "7:4", "7:04 PM"

2. **Date Format:** Dates should be in ISO format "YYYY-MM-DD"

   - ✅ Valid: "2026-01-15"
   - ❌ Invalid: "01/15/2026", "15-01-2026"

3. **Whitespace Handling:** The parser automatically trims whitespace

   - "07: 04" → parsed as "07:04"
   - " 2026-01-15 " → parsed as "2026-01-15"

4. **Campaign vs Media Restrictions:**
   - **Campaign restrictions** are checked FIRST
   - If campaign restrictions fail → Media restrictions are NOT checked
   - If campaign restrictions pass → Then media restrictions are checked

---

## 🎯 SUMMARY TABLE

| Operator     | Time Behavior                               | Date Behavior                               |
| ------------ | ------------------------------------------- | ------------------------------------------- |
| `is-between` | Plays between two times (inclusive)         | Plays between two dates (inclusive)         |
| `on`         | Plays ONLY at exact time, stops next minute | Plays on/after date, continues indefinitely |
| `is-before`  | Plays before time, stops at time            | Plays before date, stops at date            |
| `is-after`   | Plays after time, continues indefinitely    | Plays after date, continues indefinitely    |
| `not-on`     | Plays all time except target time           | Plays all dates except target date          |




