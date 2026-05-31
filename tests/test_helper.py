import json
import sys
import pytest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / 'quicktag.lrplugin'))

from helper import parse_args, load_input, write_output


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
