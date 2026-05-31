import json
import sys
import pytest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / 'quicktag.lrplugin'))

from helper import parse_args, load_input, write_output, build_prompt, parse_keywords


def test_parse_args_requires_input_and_output(tmp_path):
    with pytest.raises(SystemExit):
        parse_args(['--input', 'in.json'])


def test_load_input_reads_json(tmp_path):
    data = {'images': [{'original_path': '/a.jpg', 'preview_path': '/tmp/a.jpg'}], 'existing_keywords': ['mountain']}
    p = tmp_path / 'in.json'
    p.write_text(json.dumps(data))
    result = load_input(str(p))
    assert result['existing_keywords'] == ['mountain']
    assert len(result['images']) == 1


def test_write_output_creates_json(tmp_path):
    out = tmp_path / 'out.json'
    write_output(str(out), {'/a.jpg': ['mountain']}, [], None, 4.5)
    data = json.loads(out.read_text())
    assert data['results'] == {'/a.jpg': ['mountain']}
    assert data['skipped'] == []
    assert data['error'] is None
    assert data['seconds_per_image'] == 4.5


def test_write_output_with_error(tmp_path):
    out = tmp_path / 'out.json'
    write_output(str(out), {}, [], 'Ollama not running', 0)
    data = json.loads(out.read_text())
    assert data['error'] == 'Ollama not running'
    assert data['results'] == {}


def test_build_prompt_injects_existing_keywords():
    prompt = build_prompt(['mountain', 'sunset'], 20, 'Analyze {existing_keywords} max {max_keywords}')
    assert 'mountain, sunset' in prompt
    assert '20' in prompt


def test_build_prompt_handles_empty_keywords():
    prompt = build_prompt([], 15, 'list: {existing_keywords} max {max_keywords}')
    assert 'none yet' in prompt
    assert '15' in prompt


def test_parse_keywords_returns_clean_list():
    result = parse_keywords('Mountain, Golden Hour,  mist , pine forest')
    assert result == ['mountain', 'golden hour', 'mist', 'pine forest']


def test_parse_keywords_deduplicates():
    result = parse_keywords('mountain, forest, mountain, tree')
    assert result == ['mountain', 'forest', 'tree']


def test_parse_keywords_ignores_empty_entries():
    result = parse_keywords('mountain,,, sunset,')
    assert result == ['mountain', 'sunset']
