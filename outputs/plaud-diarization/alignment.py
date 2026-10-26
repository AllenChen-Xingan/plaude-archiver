"""Conservative interval alignment. Inputs are ASR words, never generated text."""
import math

EPS = 1e-8

def align(words, segments, duration):
    intervals = []
    for s in segments:
        a, b = s['startTimeSeconds'], s['endTimeSeconds']
        if not all(math.isfinite(t) for t in (a, b)) or a < 0 or b < a or b > duration + .1:
            raise ValueError('Invalid diarization interval')
        intervals.append((a, min(b, duration), str(s['speakerId'])))
    result = []
    previous = -1
    for w in words:
        a, b = w['startTime'], w['endTime']
        if not all(math.isfinite(t) for t in (a, b)) or a < 0 or b < a or a < previous:
            raise ValueError('Invalid ASR timestamp sequence')
        previous = a
        a, b = min(a, duration), min(b, duration)
        hits = [(max(a, x), min(b, y), sid) for x, y, sid in intervals if min(b, y)-max(a, x) > EPS]
        points = sorted({a, b, *(p for x, y, _ in hits for p in (x, y))})
        covered = overlap = 0.0
        scores = {}
        for x, y in zip(points, points[1:]):
            active = {sid for u, v, sid in hits if u < y-EPS and v > x+EPS}
            if active:
                covered += y-x
            if len(active) > 1:
                overlap += y-x
            for sid in active:
                scores[sid] = scores.get(sid, 0) + y-x
        candidates = sorted(scores, key=lambda sid: (-scores[sid], sid))
        # Multiple sequential candidates are a turn-boundary ambiguity, even if one wins.
        status = ('unknown' if not candidates else 'overlap' if overlap > EPS else
                  'turn_boundary' if len(candidates) > 1 else
                  'partial' if covered < b-a-EPS else 'assigned')
        speaker = candidates[0] if status == 'assigned' else None
        label = speaker or ('UNKNOWN' if not candidates else
                            f'{status.upper()}[{"|".join(candidates)}]')
        result.append({**w, 'alignedStartTime': a, 'alignedEndTime': b,
                       'speaker': speaker, 'speakerLabel': label,
                       'alignment': {'status': status, 'candidates': [
                           {'speaker': sid, 'overlapSeconds': scores[sid]} for sid in candidates],
                           'uncoveredSeconds': max(0, b-a-covered),
                           'simultaneousOverlapSeconds': overlap}})
    return result

def cues(words):
    result = []
    for i, w in enumerate(words):
        a, b, label = w['alignedStartTime'], w['alignedEndTime'], w['speakerLabel']
        if (result and result[-1]['speakerLabel'] == label and
                a-result[-1]['end'] <= .8 and b-result[-1]['start'] <= 8):
            result[-1]['end'] = max(result[-1]['end'], b)
            result[-1]['words'].append(w['word'])
            result[-1]['wordIndices'].append(i)
        else:
            result.append(dict(start=a, end=b, speakerLabel=label, words=[w['word']], wordIndices=[i]))
    for c in result:
        c['text'] = ' '.join(c.pop('words'))
    return result
