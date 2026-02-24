# Available AI Models Reference

Last Updated: February 24, 2026

---

## Google Gemini Models

### Text-Out Models (Generative Text)

Core conversational and text-generation models across different generations and experimental tiers:

#### Gemini 3 Series

- `gemini-3-flash` - Fast, efficient model
- `gemini-3-pro` - Advanced reasoning and capabilities
- `gemini-3.1-pro` - Enhanced version of Gemini 3 Pro

#### Gemini 2.5 Series (CURRENTLY USING)

- `gemini-2.5-pro` - **âœ… CURRENT: Best stable model with advanced reasoning**
- `gemini-2.5-flash` - Fast, lightweight version
- `gemini-2.5-flash-lite` - Ultra-fast, minimal resource usage

#### Gemini 2 Series

- `gemini-2-flash` - Fast model from Gemini 2 generation
- `gemini-2-flash-lite` - Lightweight version
- `gemini-2-flash-exp` - Experimental fast model
- `gemini-2-pro-exp` - Experimental pro model

### Multi-Modal Generative Models

#### Image Generation

- `imagen-4-generate` - Standard image generation
- `imagen-4-ultra-generate` - Ultra quality images
- `imagen-4-fast-generate` - Fast image generation
- `nano-banana` - Gemini 2.5 Flash Preview Image
- `nano-banana-pro` - Gemini 3 Pro Image

#### Video Generation

- `veo-3-generate` - Video generation
- `veo-3-fast-generate` - Fast video generation

#### Audio/Voice (Text-to-Speech)

- `gemini-2.5-pro-tts` - High-quality TTS
- `gemini-2.5-flash-tts` - Fast TTS
- `gemini-2.5-flash-preview-tts` - Experimental TTS

### Other Models

#### Gemma 3 Family (Open Weights)

- `gemma-3-1b` - 1 billion parameters
- `gemma-3-2b` - 2 billion parameters
- `gemma-3-4b` - 4 billion parameters
- `gemma-3-12b` - 12 billion parameters
- `gemma-3-27b` - 27 billion parameters

#### Embeddings

- `gemini-embedding-1` - Text embeddings for similarity/search

#### Specialty Previews

- `computer-use-preview` - Computer interaction capabilities
- `gemini-robotics-er-1.5-preview` - Robotics applications

### Agents & Live API

- `deep-research-pro-preview` - Deep research agent
- `gemini-2.5-flash-native-audio-dialog` - Real-time low-latency audio interactions

---

## xAI Grok Models

### Language Models

High context window models with various reasoning capabilities.

#### Latest Generation (Recommended)

#### Reasoning Models

- `grok-4-1-fast-reasoning` - **â­ NEWEST: 2M context, fast reasoning**
  - Context: 2,000,000 tokens
  - Pricing: $0.20 input / $0.50 output per 1M tokens
  - Best for: Complex reasoning tasks with large context

- `grok-4-fast-reasoning` - 2M context, reasoning enabled
  - Context: 2,000,000 tokens
  - Pricing: $0.20 input / $0.50 output per 1M tokens

#### Non-Reasoning Models

- `grok-4-1-fast-non-reasoning` - 2M context, faster responses
  - Context: 2,000,000 tokens
  - Pricing: $0.20 input / $0.50 output per 1M tokens

- `grok-4-fast-non-reasoning` - 2M context version
  - Context: 2,000,000 tokens
  - Pricing: $0.20 input / $0.50 output per 1M tokens

#### Code Specialist

- `grok-code-fast-1` - Optimized for code generation
  - Context: 256,000 tokens
  - Pricing: $0.20 input / $1.50 output per 1M tokens
  - Best for: Programming tasks

#### Stable Models

- `grok-4-0709` - Stable version with large context
  - Context: 256,000 tokens
  - Pricing: $3.00 input / $15.00 output per 1M tokens

- `grok-3` - Third generation flagship
  - Context: 131,072 tokens
  - Pricing: $3.00 input / $15.00 output per 1M tokens

- `grok-3-mini` - Smaller, efficient version
  - Context: 131,072 tokens
  - Pricing: $0.30 input / $0.50 output per 1M tokens

#### Legacy/Special Purpose

- `grok-2-vision-1212` - Vision capabilities
  - Context: 32,768 tokens
  - Pricing: $2.00 input / $10.00 output per 1M tokens
  - Features: Image understanding

- `grok-beta` - **âœ… CURRENT: Latest experimental features**
  - Early access to newest capabilities

### Image & Video Generation

#### Grok Image Generation

- `grok-imagine-image-pro` - High-quality images
  - Pricing: $0.033 per image
  - Best for: Professional quality

- `grok-imagine-image` - Standard quality
  - Pricing: $0.033 per image

- `grok-2-image-1212` - Legacy image model
  - Pricing: $0.07 per image

#### Grok Video Generation

- `grok-imagine-video` - Video creation
  - Pricing: $0.05 per second of video

### Coming Soon (Early Access Required)

- `grok-420` - Unreleased flagship model
- `grok-420-multi-agent` - Multi-agent system capabilities

---

## Current Configuration

### Profile: Gemini_1

- Model: `gemini-2.5-pro`
- Embedding: `gemini-embedding-001` (Google Cloud)
- API Key: `GEMINI_API_KEY`
- Compute: Cloud-based
- Status: Active

### Profile: Gemini_2

- Model: `gemini-2.5-pro`
- Embedding: `gemini-embedding-001` (Google Cloud)
- API Key: `GEMINI_API_KEY`
- Compute: Cloud-based
- Status: Active

### Profile: Grok_1

- Model: `grok-code-fast-1`
- Embedding: `gemini-embedding-001` (Google Cloud, via GEMINI_API_KEY)
- API Key: `XAI_API_KEY`
- Compute: Cloud-based
- Status: Active

---

## Model Selection Guide

### For Best Reasoning (Current Setup)

- **Gemini**: `gemini-2.5-pro` - Most stable, best reasoning
- **Grok**: `grok-code-fast-1` (code specialist) or `grok-4-1-fast-reasoning` for large context

### For Fastest Responses

- **Gemini**: `gemini-2.5-flash` or `gemini-2.5-flash-lite`
- **Grok**: `grok-4-1-fast-non-reasoning` or `grok-3-mini`

### For Coding Tasks

- **Gemini**: `gemini-2.5-pro` (excellent at code)
- **Grok**: `grok-code-fast-1` (specialized for code)

### For Large Context

- **Gemini**: `gemini-2.5-pro` (supports large contexts)
- **Grok**: `grok-4-1-fast-reasoning` or `grok-4-fast-reasoning` (2M tokens!)

### For Cost Efficiency

- **Gemini**: `gemini-2.5-flash-lite` (minimal cost)
- **Grok**: `grok-3-mini` ($0.30/$0.50 per 1M tokens)

---

## How to Change Models

Edit the profile files in `./profiles/`:

### For Gemini agents

```json
{
    "name": "gemini",
    "model": "gemini-2.5-pro",
    // ... other settings
}

```

### For Grok agent

```json
{
    "name": "Grok",
    "model": "grok-beta",
    // ... other settings
}

```

Then restart the mindcraft container:

```bash
docker-compose restart mindcraft

```

---

## API Documentation

- **Gemini**: <https://ai.google.dev/gemini-api/docs/models/gemini>
- **xAI Grok**: <https://docs.x.ai/docs>
- **API Keys**: Stored in `keys.json` (never commit!)

---

## Notes

- All pricing shown is approximate and subject to change
- Context windows indicate maximum tokens the model can process
- Some experimental models may have limited availability
- Vision models require `allow_vision: true` in settings.js (currently disabled due to Docker WebGL limitations)
- Always test new models in a safe environment before production use

---

**Last Model Update**: February 24, 2026
**Current Gemini Model**: `gemini-2.5-pro`
**Current Grok Model**: `grok-beta`
