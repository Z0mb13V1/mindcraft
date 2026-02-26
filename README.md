<!-- markdownlint-disable MD013 -->
# 🧠mindcraft⛏️

[![CI/CD Pipeline](https://github.com/Z0mb13V1/mindcraft-0.1.3/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/Z0mb13V1/mindcraft-0.1.3/actions/workflows/ci-cd.yml)
[![Trendshift](https://trendshift.io/api/badge/repositories/9163)](https://trendshift.io/repositories/9163)

Crafting minds for Minecraft with LLMs and [Mineflayer](https://prismarinejs.github.io/mineflayer/#/)!

**Links:** [FAQ](https://github.com/mindcraft-bots/mindcraft/blob/main/FAQ.md) |
[Discord Support](https://discord.gg/mp73p35dzC) |
[Video Tutorial](https://www.youtube.com/watch?v=gRotoL8P8D8) |
[Blog Post](https://kolbynottingham.com/mindcraft/) |
[Contributor TODO](https://github.com/users/kolbytn/projects/1) |
[Paper Website](https://mindcraft-minecollab.github.io/index.html) |
[MineCollab](https://github.com/mindcraft-bots/mindcraft/blob/main/minecollab.md)

> [!Caution]
Do not connect this bot to public servers with coding enabled. This project allows an LLM to write/execute code on your computer. The code is sandboxed, but still vulnerable to injection attacks. Code writing is disabled by default, you can enable it by setting `allow_insecure_coding` to `true` in `settings.js`. Ye be warned.

---

## This Fork: Hybrid Research Rig

This fork (`mindcraft-0.1.3`) extends the base Mindcraft framework with a **Hybrid Research Rig** — two AI bots running simultaneously on AWS EC2, combining cloud ensemble intelligence with local GPU inference.

> **Live deployment**: All services run on AWS EC2 via `docker-compose.aws.yml`. See the [Architecture wiki](https://github.com/Z0mb13V1/mindcraft-0.1.3/wiki/Architecture) for full infrastructure diagrams.

### Active Bots

| Bot | Model | Vision | Role |
| --- | ----- | ------ | ---- |
| **CloudGrok** | 4-model ensemble (Gemini + Grok panel) | `grok-2-vision-1212` | Persistent survival bot — base maintenance, resource gathering, building |
| **LocalAndy** | `sweaterdog/andy-4` via Ollama (RTX 3090) | `gemini-2.5-flash` | Research & exploration bot — biome exploration, strategy testing |

### Ensemble Decision Pipeline (CloudGrok)

| Phase | Name | Description |
| ----- | ---- | ----------- |
| **1** | Heuristic Arbiter | All 4 panel models queried in parallel; proposals scored on length, completeness, and action quality — highest score wins |
| **2** | LLM-as-Judge | When top two proposals are within 0.08 margin, Gemini Flash reviews all proposals and picks the winner |
| **3** | ChromaDB Memory | Before querying the panel, similar past decisions (similarity > 0.6) are retrieved via 3072-dim Gemini embeddings and injected as `[PAST EXPERIENCE]` context |

### Panel Models (CloudGrok Ensemble)

| Model | Provider | Role |
| ----- | -------- | ---- |
| `gemini-2.5-pro` | Google | Panel member |
| `gemini-2.5-flash` | Google | Panel member + LLM Judge |
| `grok-4-1-fast-non-reasoning` | xAI | Panel member |
| `grok-code-fast-1` | xAI | Panel member |

### Infrastructure

| Component | Location |
| --------- | -------- |
| Minecraft server | AWS EC2 (us-east-1) — `ONLINE_MODE=FALSE` |
| CloudGrok (ensemble bot) | AWS EC2 (us-east-1) — cloud APIs |
| LocalAndy (Ollama bot) | AWS EC2 (us-east-1) — inference on local RTX 3090 via Tailscale |
| ChromaDB vector store | AWS EC2 (us-east-1) |
| Discord bot | AWS EC2 (us-east-1) — MindcraftBot#9501 |
| Ollama (inference) | Local Windows PC (RTX 3090) — connected via Tailscale VPN |
| S3 backup | Daily 3 AM UTC, 7-day retention |

### Running the Hybrid Rig

```bash
# AWS deployment (both bots + all services)
docker compose -f docker-compose.aws.yml up --build

# Profiles are set in SETTINGS_JSON env var:
# PROFILES='["./profiles/cloud-persistent.json", "./profiles/local-research.json"]'
```

### Key Features

- **Vision enabled** for both bots — `xvfb-run` + Mesa software rendering in Docker (`LIBGL_ALWAYS_SOFTWARE=1`)
- **Human message priority** — `requestInterrupt()` fires immediately when a human player speaks
- **Loop detection** — tracks last 12 actions, cancels on 3-action pattern repeats or 5+ of the same action
- **Per-profile `blocked_actions`** — LocalAndy blocks `!startConversation` to prevent hallucinated names
- **Graceful vision fallback** — if WebGL init fails, bots continue without crashing

### Security

This fork includes several security hardening measures:

- **Environment variable keys** — API keys loaded from `.env` / env vars (priority over `keys.json`). See `.env.example`.
- **Recursive prototype pollution protection** — `SETTINGS_JSON` sanitized at all nesting depths
- **Cross-platform path traversal guard** — Discord bot profile paths validated with `path.sep`
- **Input validation** — message validator with command injection detection, type checks, control char stripping
- **Rate limiting with auto-cleanup** — prevents abuse and memory leaks from stale entries
- **Docker non-root user** — container runs as `mindcraft` user, not root
- **ESLint hardening** — `no-unused-vars`, `no-unreachable`, `no-floating-promise` enabled as warnings

See the [Security wiki page](https://github.com/Z0mb13V1/mindcraft-0.1.3/wiki/Security) for full details.

See the [wiki](https://github.com/Z0mb13V1/mindcraft-0.1.3/wiki) for full documentation.

---

## Getting Started

## Requirements

- [Minecraft Java Edition](https://www.minecraft.net/en-us/store/minecraft-java-bedrock-edition-pc) (up to v1.21.6, recommend v1.21.6)
- [Node.js Installed](https://nodejs.org/) (Node v18 or v20 LTS recommended. Node v24+ may cause issues with native dependencies)
- At least one API key from a supported API provider. See [supported APIs](#model-customization). OpenAI is the default.

> [!Important]
> If installing node on windows, ensure you check `Automatically install the necessary tools`
>
> If you encounter `npm install` errors on macOS, see the [FAQ](FAQ.md#common-issues) for troubleshooting native module build issues

## Install and Run

1. Make sure you have the requirements above.

2. Download the [latest release](https://github.com/mindcraft-bots/mindcraft/releases/latest) and unzip it, or clone the repository.

3. Set up your API keys (you only need one provider):
   - **Recommended:** Copy `.env.example` to `.env` and fill in your keys. Environment variables take priority.
   - **Legacy:** Rename `keys.example.json` to `keys.json` and fill in your keys. *(Less secure — migrate to `.env` when possible.)*

4. In terminal/command prompt, run `npm install` from the installed directory

5. Start a minecraft world and open it to LAN on localhost port `55916`

6. Run `node main.js` from the installed directory

If you encounter issues, check the [FAQ](https://github.com/mindcraft-bots/mindcraft/blob/main/FAQ.md) or find support on [discord](https://discord.gg/mp73p35dzC). We are currently not very responsive to github issues. To run tasks please refer to [Minecollab Instructions](minecollab.md#installation)

## Configuration

## Model Customization

You can configure project details in `settings.js`. [See file.](settings.js)

You can configure the agent's name, model, and prompts in their profile like `andy.json`. The model can be specified with the `model` field, with values like `model: "gemini-2.5-pro"`. You will need the correct API key for the API provider you choose. See all supported APIs below.

### Supported APIs

| API Name | Config Variable | Docs |
| ------ | ------ | ------ |
| `openai` | `OPENAI_API_KEY` | [docs](https://platform.openai.com/docs/models) |
| `google` | `GEMINI_API_KEY` | [docs](https://ai.google.dev/gemini-api/docs/models/gemini) |
| `anthropic` | `ANTHROPIC_API_KEY` | [docs](https://docs.anthropic.com/claude/docs/models-overview) |
| `xai` | `XAI_API_KEY` | [docs](https://docs.x.ai/docs) |
| `deepseek` | `DEEPSEEK_API_KEY` | [docs](https://api-docs.deepseek.com/) |
| `ollama` (local) | n/a | [docs](https://ollama.com/library) |
| `qwen` | `QWEN_API_KEY` | [Intl.](https://www.alibabacloud.com/help/en/model-studio/developer-reference/use-qwen-by-calling-api)/[cn](https://help.aliyun.com/zh/model-studio/getting-started/models) |
| `mistral` | `MISTRAL_API_KEY` | [docs](https://docs.mistral.ai/getting-started/models/models_overview/) |
| `replicate` | `REPLICATE_API_KEY` | [docs](https://replicate.com/collections/language-models) |
| `groq` (not grok) | `GROQCLOUD_API_KEY` | [docs](https://console.groq.com/docs/models) |
| `huggingface` | `HUGGINGFACE_API_KEY` | [docs](https://huggingface.co/models) |
| `novita` | `NOVITA_API_KEY` | [docs](https://novita.ai/model-api/product/llm-api?utm_source=github_mindcraft&utm_medium=github_readme&utm_campaign=link) |
| `openrouter` | `OPENROUTER_API_KEY` | [docs](https://openrouter.ai/models) |
| `glhf` | `GHLF_API_KEY` | [docs](https://glhf.chat/user-settings/api) |
| `hyperbolic` | `HYPERBOLIC_API_KEY` | [docs](https://docs.hyperbolic.xyz/docs/getting-started) |
| `vllm` | n/a | n/a |
| `cerebras` | `CEREBRAS_API_KEY` | [docs](https://inference-docs.cerebras.ai/introduction) |
| `mercury` | `MERCURY_API_KEY` | [docs](https://www.inceptionlabs.ai/) |

For more comprehensive model configuration and syntax, see [Model Specifications](#model-specifications).

For local models we support [ollama](https://ollama.com/) and we provide our own finetuned models for you to use.
To install our models, install ollama and run the following terminal command:

```bash
ollama pull sweaterdog/andy-4:micro-q8_0 && ollama pull embeddinggemma
```

## Online Servers

To connect to online servers your bot will need an official Microsoft/Minecraft account. You can use your own personal one, but will need another account if you want to connect too and play with it. To connect, change these lines in `settings.js`:

```javascript
"host": "111.222.333.444",
"port": 55920,
"auth": "microsoft",

// rest is same...
```

> [!Important]
> The bot's name in the profile.json must exactly match the Minecraft profile name! Otherwise the bot will spam talk to itself.

To use different accounts, Mindcraft will connect with the account that the Minecraft launcher is currently using. You can switch accounts in the launcher, then run `node main.js`, then switch to your main account after the bot has connected.

## Tasks

Tasks automatically start the bot with a prompt and a goal item to aquire or blueprint to construct. To run a simple task that involves collecting 4 oak_logs run

`node main.js --task_path tasks/basic/single_agent.json --task_id gather_oak_logs`

Here is an example task json format:

```json
{
    "gather_oak_logs": {
      "goal": "Collect at least four logs",
      "initial_inventory": {
        "0": {
          "wooden_axe": 1
        }
      },
      "agent_count": 1,
      "target": "oak_log",
      "number_of_target": 4,
      "type": "techtree",
      "max_depth": 1,
      "depth": 0,
      "timeout": 300,
      "blocked_actions": {
        "0": [],
        "1": []
      },
      "missing_items": [],
      "requires_ctable": false
    }
}
```

The `initial_inventory` is what the bot will have at the start of the episode, `target` refers to the target item and `number_of_target` refers to the number of target items the agent needs to collect to successfully complete the task.

If you want more optimization and automatic launching of the minecraft world, you will need to follow the instructions in [Minecollab Instructions](minecollab.md#installation)

## Docker Container

If you intend to `allow_insecure_coding`, it is a good idea to run the app in a docker container to reduce risks of running unknown code. This is strongly recommended before connecting to remote servers, although still does not guarantee complete safety.

```bash
docker build -t mindcraft . && docker run --rm --add-host=host.docker.internal:host-gateway -p 8080:8080 -p 3000-3003:3000-3003 -e SETTINGS_JSON='{"auto_open_ui":false,"profiles":["./profiles/gemini.json"],"host":"host.docker.internal"}' --volume ./keys.json:/app/keys.json --name mindcraft mindcraft
```

or simply

```bash
docker-compose up --build
```

When running in docker, if you want the bot to join your local minecraft server, you have to use a special host address `host.docker.internal` to call your localhost from inside your docker container. Put this into your [settings.js](settings.js):

```javascript
"host": "host.docker.internal", // instead of "localhost", to join your local minecraft from inside the docker container
```

To connect to an unsupported minecraft version, you can try to use [viaproxy](services/viaproxy/README.md)

## Bot Profiles

Bot profiles are json files (such as `andy.json`) that define:

1. Bot backend LLMs to use for talking, coding, and embedding.
2. Prompts used to influence the bot's behavior.
3. Examples help the bot perform tasks.

## Model Specifications

LLM models can be specified simply as `"model": "gpt-4o"`, or more specifically with `"{api}/{model}"`, like `"openrouter/google/gemini-2.5-pro"`. See all [supported APIs](#model-customization).

The `model` field can be a string or an object. A model object must specify an `api`, and optionally a `model`, `url`, and additional `params`. You can also use different models/providers for chatting, coding, vision, embedding, and voice synthesis. See the example below.

```json
"model": {
  "api": "openai",
  "model": "gpt-4o",
  "url": "https://api.openai.com/v1/",
  "params": {
    "max_tokens": 1000,
    "temperature": 1
  }
},
"code_model": {
  "api": "openai",
  "model": "gpt-4",
  "url": "https://api.openai.com/v1/"
},
"vision_model": {
  "api": "openai",
  "model": "gpt-4o",
  "url": "https://api.openai.com/v1/"
},
"embedding": {
  "api": "openai",
  "url": "https://api.openai.com/v1/",
  "model": "text-embedding-ada-002"
},
"speak_model": "openai/tts-1/echo"
```

`model` is used for chat, `code_model` is used for newAction coding, `vision_model` is used for image interpretation, `embedding` is used to embed text for example selection, and `speak_model` is used for voice synthesis. `model` will be used by default for all other models if not specified. Not all APIs support embeddings, vision, or voice synthesis.

All apis have default models and urls, so those fields are optional. The `params` field is optional and can be used to specify additional parameters for the model. It accepts any key-value pairs supported by the api. Is not supported for embedding models.

## Embedding Models

Embedding models are used to embed and efficiently select relevant examples for conversation and coding.

Supported Embedding APIs: `openai`, `google`, `replicate`, `huggingface`, `novita`

If you try to use an unsupported model, then it will default to a simple word-overlap method. Expect reduced performance. We recommend using supported embedding APIs.

## Voice Synthesis Models

Voice synthesis models are used to narrate bot responses and specified with `speak_model`. This field is parsed differently than other models and only supports strings formatted as `"{api}/{model}/{voice}"`, like `"openai/tts-1/echo"`. We only support `openai` and `google` for voice synthesis.

## Specifying Profiles via Command Line

By default, the program will use the profiles specified in `settings.js`. You can specify one or more agent profiles using the `--profiles` argument: `node main.js --profiles ./profiles/andy.json ./profiles/jill.json`

## Contributing

We welcome contributions to the project! We are generally less responsive to github issues, and more responsive to pull requests. Join the [discord](https://discord.gg/mp73p35dzC) for more active support and direction.

While AI generated code is allowed, please vet it carefully. Submitting tons of sloppy code and documentation actively harms development.

## Patches

Some of the node modules that we depend on have bugs in them. To add a patch, change your local node module file and run `npx patch-package [package-name]`

### Development Team

Thanks to all who contributed to the project, especially the official development team: [@MaxRobinsonTheGreat](https://github.com/MaxRobinsonTheGreat), [@kolbytn](https://github.com/kolbytn), [@icwhite](https://github.com/icwhite), [@Sweaterdog](https://github.com/Sweaterdog), [@Ninot1Quyi](https://github.com/Ninot1Quyi), [@riqvip](https://github.com/riqvip), [@uukelele-scratch](https://github.com/uukelele-scratch), [@mrelmida](https://github.com/mrelmida)

### Citation

This work is published in the paper [Collaborating Action by Action: A Multi-agent LLM Framework for Embodied Reasoning](https://arxiv.org/abs/2504.17950). Please use this citation if you use this project in your research:

```bibtex
@article{mindcraft2025,
  title = {Collaborating Action by Action: A Multi-agent LLM Framework for Embodied Reasoning},
  author = {White*, Isadora and Nottingham*, Kolby and Maniar, Ayush and Robinson, Max and Lillemark, Hansen and Maheshwari, Mehul and Qin, Lianhui and Ammanabrolu, Prithviraj},
  journal = {arXiv preprint arXiv:2504.17950},
  year = {2025},
  url = {https://arxiv.org/abs/2504.17950},
}
```
