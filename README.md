# QuickTag

Automatically apply AI-generated keywords to selected photos in Lightroom Classic. All processing runs locally on your machine — no internet connection, no cloud service, no subscription.

Select photos, click **Library → QuickTag Selected Images**, and keywords are applied directly to your catalog.

---

## How it works

QuickTag runs a local AI vision model ([Ollama](https://ollama.com)) against each photo's preview, then writes the generated keywords back into Lightroom via the SDK. No photos leave your machine.

---

## Prerequisites

You need three things installed before QuickTag will work:

### 1. Ollama

Download and install from [ollama.com](https://ollama.com). After installing, Ollama runs as a background service automatically.

### 2. A vision model

Pull the default model (requires ~4 GB of disk space):

```
ollama pull llava
```

Other supported models: `moondream` (~1.7 GB, faster, less accurate), `llava:13b` (higher accuracy, needs more VRAM).

### 3. Python 3

Download from [python.org](https://www.python.org/downloads/). During installation on Windows, check **"Add Python to PATH"**.

Then install the Ollama Python library:

```
pip install ollama
```

---

## Installation

1. Download `quicktag-v1.0.0.zip` from the [latest release](https://github.com/mudman3/QuickTag/releases/latest)
2. Unzip it — you'll get a folder named `quicktag.lrplugin`
3. In Lightroom Classic: **File → Plug-in Manager → Add**
4. Navigate to and select the `quicktag.lrplugin` folder
5. Click **Enable**

---

## Usage

1. Select one or more photos (or a folder) in the Library module
2. Go to **Library → QuickTag Selected Images**
3. Review the pre-run summary and click **Run**
4. Wait — a progress bar shows estimated time remaining
5. Keywords are applied when complete

On the first run, QuickTag measures how long your machine takes per image and updates `seconds_per_image` in `config.json` automatically. Subsequent time estimates will be accurate.

---

## Configuration

Edit `quicktag.lrplugin/config.json` to customise behaviour:

| Key | Default | Description |
|---|---|---|
| `model` | `"llava"` | Ollama model to use for tagging |
| `max_keywords` | `10` | Maximum keywords to generate per photo |
| `prompt` | *(see file)* | The prompt sent to the model — edit to focus on specific subjects |
| `python_path` | `"python"` | Path to Python if it's not on your system PATH |
| `seconds_per_image` | `10` | Time estimate per image (auto-updated after each run) |

**Custom Python path example (Windows):**
```json
"python_path": "C:\\Users\\YourName\\AppData\\Local\\Programs\\Python\\Python313\\python.exe"
```

---

## Troubleshooting

**"Ollama Python library not installed"**
Run `pip install ollama` in a terminal. If you have multiple Python installs, make sure you're installing into the same one Lightroom will call (set `python_path` in config.json to be explicit).

**"QuickTag couldn't connect to Ollama"**
Ollama must be running. On Windows it usually starts automatically with your system; check the system tray or run `ollama serve` in a terminal.

**"Model 'llava' not found"**
Run `ollama pull llava` in a terminal. The model hasn't been downloaded yet.

**Photos are skipped**
If Lightroom can't generate a preview (e.g. the file is offline or the preview hasn't rendered yet), the photo is skipped and listed in the completion summary.

**Keywords look wrong**
Try editing the `prompt` in `config.json`. You can also try a more capable model: `ollama pull llava:13b`.

---

## License

MIT — see [LICENSE](LICENSE).
