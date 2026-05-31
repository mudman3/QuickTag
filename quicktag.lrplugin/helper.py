import argparse
import json
import sys


def parse_args(args=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    return parser.parse_args(args)


def load_input(input_path):
    with open(input_path) as f:
        return json.load(f)


def write_output(output_path, results, skipped, error, seconds_per_image):
    with open(output_path, 'w') as f:
        json.dump({
            'results': results,
            'skipped': skipped,
            'error': error,
            'seconds_per_image': seconds_per_image,
        }, f)


if __name__ == '__main__':
    args = parse_args()
