import json
import sys
import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).parent.parent / 'quicktag.lrplugin'))

from helper import parse_args, load_input, write_output, build_prompt, parse_keywords, analyze_image, check_ollama, OllamaNotRunningError, ModelNotFoundError, update_config, run


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


def test_analyze_image_calls_ollama_with_image(tmp_path):
    fake_image = tmp_path / 'photo.jpg'
    fake_image.write_bytes(b'fakejpeg')

    mock_response = {'message': {'content': 'mountain, sunset, golden hour'}}

    with patch('helper.ollama') as mock_ollama:
        mock_ollama.chat.return_value = mock_response
        result = analyze_image(str(fake_image), 'describe this', 'moondream')

    mock_ollama.chat.assert_called_once_with(
        model='moondream',
        messages=[{'role': 'user', 'content': 'describe this', 'images': [str(fake_image)]}]
    )
    assert result == 'mountain, sunset, golden hour'


def test_check_ollama_raises_when_not_running():
    with patch('helper.ollama.list', side_effect=Exception('connection refused')):
        with pytest.raises(OllamaNotRunningError):
            check_ollama('moondream')


def test_check_ollama_raises_when_model_missing():
    mock_list = MagicMock()
    mock_list.return_value = {'models': [{'name': 'llama3:latest'}]}
    with patch('helper.ollama.list', mock_list):
        with pytest.raises(ModelNotFoundError):
            check_ollama('moondream')


def test_check_ollama_passes_when_model_present():
    mock_list = MagicMock()
    mock_list.return_value = {'models': [{'name': 'moondream:latest'}, {'name': 'llama3:latest'}]}
    with patch('helper.ollama.list', mock_list):
        check_ollama('moondream')  # should not raise


def test_update_config_writes_seconds_per_image(tmp_path):
    config = tmp_path / 'config.json'
    config.write_text(json.dumps({'model': 'moondream', 'max_keywords': 20, 'seconds_per_image': 5}))
    update_config(str(config), 3.7)
    result = json.loads(config.read_text())
    assert result['seconds_per_image'] == 3.7


def test_update_config_silently_ignores_missing_file():
    update_config('/nonexistent/config.json', 3.7)  # should not raise


def test_run_writes_results_for_each_image(tmp_path):
    preview = tmp_path / 'preview.jpg'
    preview.write_bytes(b'fakejpeg')

    input_data = {
        'images': [{'original_path': '/photos/a.jpg', 'preview_path': str(preview)}],
        'existing_keywords': ['mountain'],
        'config_path': '',
    }
    in_file = tmp_path / 'in.json'
    in_file.write_text(json.dumps(input_data))
    out_file = tmp_path / 'out.json'

    config_data = {'model': 'moondream', 'max_keywords': 20, 'seconds_per_image': 5,
                   'prompt': 'keywords: {existing_keywords} max {max_keywords}'}

    with patch('helper.check_ollama'), \
         patch('helper.analyze_image', return_value='mountain, sunset'), \
         patch('helper.load_config', return_value=config_data):
        run(str(in_file), str(out_file))

    result = json.loads(out_file.read_text())
    assert result['error'] is None
    assert result['results']['/photos/a.jpg'] == ['mountain', 'sunset']
    assert result['skipped'] == []


def test_run_writes_error_when_ollama_not_running(tmp_path):
    input_data = {'images': [], 'existing_keywords': [], 'config_path': ''}
    in_file = tmp_path / 'in.json'
    in_file.write_text(json.dumps(input_data))
    out_file = tmp_path / 'out.json'

    config_data = {'model': 'moondream', 'max_keywords': 20, 'seconds_per_image': 5, 'prompt': ''}

    with patch('helper.check_ollama', side_effect=OllamaNotRunningError('not running')), \
         patch('helper.load_config', return_value=config_data):
        run(str(in_file), str(out_file))

    result = json.loads(out_file.read_text())
    assert 'not running' in result['error']


def test_run_skips_image_on_analysis_failure(tmp_path):
    preview = tmp_path / 'preview.jpg'
    preview.write_bytes(b'fakejpeg')

    input_data = {
        'images': [{'original_path': '/photos/bad.jpg', 'preview_path': str(preview)}],
        'existing_keywords': [],
        'config_path': '',
    }
    in_file = tmp_path / 'in.json'
    in_file.write_text(json.dumps(input_data))
    out_file = tmp_path / 'out.json'

    config_data = {'model': 'moondream', 'max_keywords': 20, 'seconds_per_image': 5, 'prompt': '{existing_keywords} {max_keywords}'}

    with patch('helper.check_ollama'), \
         patch('helper.analyze_image', side_effect=Exception('GPU error')), \
         patch('helper.load_config', return_value=config_data):
        run(str(in_file), str(out_file))

    result = json.loads(out_file.read_text())
    assert '/photos/bad.jpg' in result['skipped']
    assert result['error'] is None


def test_run_writes_error_when_model_not_found(tmp_path):
    input_data = {'images': [], 'existing_keywords': [], 'config_path': ''}
    in_file = tmp_path / 'in.json'
    in_file.write_text(json.dumps(input_data))
    out_file = tmp_path / 'out.json'

    config_data = {'model': 'moondream', 'max_keywords': 20, 'seconds_per_image': 5, 'prompt': ''}

    with patch('helper.check_ollama', side_effect=ModelNotFoundError('model not found')), \
         patch('helper.load_config', return_value=config_data):
        run(str(in_file), str(out_file))

    result = json.loads(out_file.read_text())
    assert 'model not found' in result['error']
