## QuickTag v1.0.0

First release of QuickTag — local AI keyword tagging for Lightroom Classic.

### What it does
Select photos in Lightroom, run **Library → QuickTag Selected Images**, and keywords are applied automatically using a local AI vision model. No internet required.

### Prerequisites
- [Ollama](https://ollama.com) installed and running
- A vision model pulled: `ollama pull llava`
- Python 3 with the Ollama library: `pip install ollama`

### Installation
1. Download `quicktag-v1.0.0.zip` below
2. Unzip to get the `quicktag.lrplugin` folder
3. In Lightroom: **File → Plug-in Manager → Add** → select the folder → Enable
