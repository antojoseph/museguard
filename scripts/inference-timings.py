#!/usr/bin/env python3
"""Summarize bounded, local inference metadata without reading screen content."""
import argparse
import json
from pathlib import Path


def percentile(values, fraction):
    values = sorted(value for value in values if isinstance(value, (int, float)))
    if not values:
        return None
    position = (len(values) - 1) * fraction
    low = int(position)
    return round(values[low] + (values[min(low + 1, len(values) - 1)] - values[low]) * (position - low), 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--path', type=Path, default=Path.home() / 'Library/Application Support/MuseGuard/Diagnostics/inference-metrics.json')
    args = parser.parse_args()
    if not args.path.exists():
        print('No inference timings yet. Ask Muse a question or let it check a page first.')
        return
    records = json.loads(args.path.read_text())
    report = {'records': len(records), 'definitions': {
        'queue_ms': 'Time waiting in the native inference queue.',
        'request_ms': 'HTTP request through complete response, including server wait.',
        'first_text_ms': 'HTTP request to first visible answer text; excludes screen-context collection and native queue.',
        'server_compute_ms': 'Server-reported prompt processing plus generation; excludes queueing.'}, 'operations': {}}
    for kind in sorted({record['kind'] for record in records}):
        group = [record for record in records if record['kind'] == kind]
        completed = [record for record in group if record['outcome'] == 'completed']
        response = [record.get('response') or {} for record in completed]
        fields = {
            'queue_ms': [record.get('queueMilliseconds') for record in completed],
            'work_ms': [record.get('workMilliseconds') for record in completed],
            'request_ms': [item.get('requestMilliseconds') for item in response],
            'first_text_ms': [item.get('firstVisibleMilliseconds') for item in response],
            'decode_tokens_per_second': [item.get('tokensPerSecond') for item in response],
            'server_compute_ms': [item['promptMilliseconds'] + item['generationMilliseconds'] for item in response
                                  if isinstance(item.get('promptMilliseconds'), (int, float)) and isinstance(item.get('generationMilliseconds'), (int, float))]}
        report['operations'][kind] = {'completed': len(completed), 'cancelled': sum(item['outcome'] == 'cancelled' for item in group),
            'failed': sum(item['outcome'] == 'failed' for item in group),
            'timings': {name: {'samples': sum(isinstance(value, (int, float)) for value in values),
                'median': percentile(values, 0.5), 'p90': percentile(values, 0.9)} for name, values in fields.items()}}
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
