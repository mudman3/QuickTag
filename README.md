# QuickTag

Automatically apply AI-generated keywords to photos in Lightroom Classic using a local AI model. No internet required — all processing happens on your machine.

## Setup

1. Install [Ollama](https://ollama.com) and start it
2. Run: `ollama pull moondream`
3. Install [Python 3](https://python.org)
4. Run: `pip install ollama`
5. Copy `quicktag.lrplugin` into your Lightroom plugins folder
6. In Lightroom: File → Plug-in Manager → Add → select `quicktag.lrplugin` → Enable

## Usage

1. Select photos or a folder in Lightroom
2. Library menu → QuickTag Selected Images
3. Review the pre-run dialog and click Run
4. Wait for completion — keywords are applied automatically

## Configuration

Edit `quicktag.lrplugin/config.json` to change the model, keyword count, or prompt.
