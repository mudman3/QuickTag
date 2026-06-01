import argparse
import json
import time
try:
    import ollama
except ImportError:
    ollama = None  # type: ignore


class OllamaNotRunningError(Exception):
    pass


class ModelNotFoundError(Exception):
    pass


def check_ollama(model):
    if ollama is None:
        raise OllamaNotRunningError(
            "Ollama Python library not installed. Run: pip install ollama"
        )
    try:
        response = ollama.list()
    except Exception:
        raise OllamaNotRunningError(
            "QuickTag couldn't connect to Ollama. Make sure Ollama is running."
        )
    # Newer ollama library returns a ListResponse object; older returns a dict
    if hasattr(response, 'models'):
        installed = [m.model.split(':')[0] for m in response.models]
    else:
        installed = [m['name'].split(':')[0] for m in response.get('models', [])]
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
    return (template
            .replace('{existing_keywords}', existing)
            .replace('{max_keywords}', str(max_keywords)))


_STOP_WORDS = {
    # articles / conjunctions / prepositions
    'a', 'an', 'the', 'and', 'or', 'but', 'with', 'of', 'in', 'on', 'at',
    'to', 'for', 'by', 'as', 'from', 'into', 'along', 'through', 'towards',
    'above', 'below', 'around', 'between', 'across', 'over', 'under',
    'near', 'beside', 'behind', 'front',
    # positional / relational
    'side', 'sides', 'either', 'both', 'left', 'right', 'top', 'bottom',
    'middle', 'center', 'centre', 'back', 'each', 'other',
    'background', 'foreground', 'distance', 'horizon',
    # pronouns / determiners
    'it', 'its', 'this', 'that', 'these', 'those', 'there', 'their',
    'they', 'them', 'we', 'our', 'which', 'where', 'what',
    # meta-words (about the photo itself)
    'image', 'photo', 'picture', 'photograph', 'scene', 'shot', 'view',
    # verbs and participles
    'is', 'are', 'was', 'were', 'be', 'been', 'has', 'have', 'had',
    'can', 'could', 'appears', 'appear', 'seems', 'seem', 'depicts',
    'shows', 'show', 'creates', 'create', 'giving', 'adding', 'lining',
    'winding', 'casting', 'extending', 'leads', 'leading', 'visible',
    'gives', 'makes', 'make', 'extend', 'taken', 'showing', 'featuring',
    # adverbs / qualifiers
    'no', 'not', 'some', 'also', 'almost', 'very', 'quite', 'just',
    'while', 'where', 'when', 'here',
}

def parse_keywords(response_text):
    import re

    # Clean the text
    text = re.sub(r'[^\w\s\'-]', ' ', response_text.lower()).strip()
    tokens = text.split()

    seen = set()
    result = []

    def add(phrase):
        phrase = phrase.strip()
        if len(phrase) > 1 and phrase not in seen:
            seen.add(phrase)
            result.append(phrase)

    # First try comma-split (model may have followed instructions)
    if ',' in response_text:
        for part in response_text.split(','):
            phrase = re.sub(r'[^\w\s\'-]', '', part).strip().lower()
            # Strip leading stop words (e.g. "and sky" → "sky")
            words = phrase.split()
            while words and words[0] in _STOP_WORDS:
                words = words[1:]
            phrase = ' '.join(words)
            if phrase:
                add(phrase)
        return result

    # No commas — sentence mode: group consecutive meaningful tokens into
    # 1-2 word phrases (compound nouns like "dirt road", "overcast sky")
    i = 0
    while i < len(tokens):
        word = re.sub(r"[^\w'-]", '', tokens[i])
        if not word or word in _STOP_WORDS or len(word) <= 2:
            i += 1
            continue
        # Look ahead: can we form a 2-word phrase?
        if i + 1 < len(tokens):
            next_word = re.sub(r"[^\w'-]", '', tokens[i + 1])
            if next_word and next_word not in _STOP_WORDS and len(next_word) > 2:
                add(word + ' ' + next_word)
                i += 2
                continue
        add(word)
        i += 1

    return result


def analyze_image(image_path, prompt, model):
    with open(image_path, 'rb') as f:
        image_bytes = f.read()
    response = ollama.generate(
        model=model,
        prompt=prompt,
        images=[image_bytes],
        stream=False,
    )
    text = response.response if hasattr(response, 'response') else response['response']
    import sys
    print(f"[{image_path}] {repr(text.strip())}", file=sys.stderr)
    return text.strip()


def load_config(config_path):
    try:
        with open(config_path) as f:
            return json.load(f)
    except Exception:
        return {'model': 'moondream', 'max_keywords': 20, 'seconds_per_image': 5, 'prompt': ''}


def update_config(config_path, seconds_per_image):
    try:
        with open(config_path) as f:
            config = json.load(f)
        config['seconds_per_image'] = round(seconds_per_image, 1)
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=2)
    except Exception:
        pass


def run(input_path, output_path):
    data = load_input(input_path)
    images = data.get('images', [])
    existing_keywords = data.get('existing_keywords', [])
    config_path = data.get('config_path', '')

    config = load_config(config_path)
    model = config.get('model', 'moondream')
    max_keywords = config.get('max_keywords', 20)
    prompt_template = config.get('prompt', '')

    try:
        check_ollama(model)
    except (OllamaNotRunningError, ModelNotFoundError) as e:
        write_output(output_path, {}, [], str(e), 0)
        return

    prompt = build_prompt(existing_keywords, max_keywords, prompt_template)
    results = {}
    skipped = []
    times = []

    for item in images:
        original_path = item['original_path']
        preview_path = item['preview_path']
        try:
            start = time.time()
            response = analyze_image(preview_path, prompt, model)
            elapsed = time.time() - start
            times.append(elapsed)
            results[original_path] = parse_keywords(response)
        except Exception:
            skipped.append(original_path)

    avg_time = round(sum(times) / len(times), 1) if times else 0
    if config_path and avg_time > 0:
        update_config(config_path, avg_time)

    write_output(output_path, results, skipped, None, avg_time)


if __name__ == '__main__':
    args = parse_args()
    run(args.input, args.output)
