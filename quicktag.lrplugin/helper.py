import argparse
import json
import ollama


class OllamaNotRunningError(Exception):
    pass


class ModelNotFoundError(Exception):
    pass


def check_ollama(model):
    try:
        response = ollama.list()
    except Exception:
        raise OllamaNotRunningError(
            "QuickTag couldn't connect to Ollama. Make sure Ollama is running."
        )
    models = response.get('models', [])
    installed = [m['name'].split(':')[0] for m in models]
    if model not in installed:
        raise ModelNotFoundError(
            f"Model '{model}' not found. Run: ollama pull {model}"
        )


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


def build_prompt(existing_keywords, max_keywords, template):
    existing = ', '.join(existing_keywords) if existing_keywords else 'none yet'
    return template.replace('{existing_keywords}', existing).replace('{max_keywords}', str(max_keywords))


def parse_keywords(response_text):
    parts = response_text.split(',')
    seen = set()
    result = []
    for part in parts:
        word = part.strip().lower()
        if word and word not in seen:
            seen.add(word)
            result.append(word)
    return result


def analyze_image(image_path, prompt, model):
    response = ollama.chat(
        model=model,
        messages=[{'role': 'user', 'content': prompt, 'images': [image_path]}]
    )
    return response['message']['content']


if __name__ == '__main__':
    args = parse_args()
