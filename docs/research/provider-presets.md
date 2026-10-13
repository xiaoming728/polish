# 大模型厂商预设清单与协议差异

回应 [#5](https://github.com/xiaoming728/polish/issues/5)（母地图 [#1](https://github.com/xiaoming728/polish/issues/1)）。调研日期 2026-10-13。全部结论来自官方文档与三个参考项目源码；只读取公开文档，未调用任何需要 API Key 的接口。

标注约定：**[官方]** 官方文档明确写出；**[参考]** 仅见于 Cherry Studio / LobeChat / Easydict 源码；**[未证实]** 本次没有找到一手证据，实现前需用真实 Key 实测。

## 1. 结论（先看这里）

1. 12 家候选里，**只有 Anthropic 必须走原生协议**（`/v1/messages`，`x-api-key`，事件流）。其余 11 家都提供 OpenAI 兼容的 `POST {base}/chat/completions` + `Authorization: Bearer`，流式都以 `data: [DONE]` 结尾。
2. 厂商之间的真正差异不在 URL，而在三点：思考内容字段（`reasoning_content` / `reasoning` / `thinking_delta`）、关闭思考的请求参数（各家不同）、`/models` 的返回内容是否可直接当"可选模型"用。
3. 润色场景不需要思考过程：**首版应默认关闭或忽略思考内容**，只拼接 `delta.content`，就能绕开 80% 的方言差异。
4. 预设本质上只是 `{名称, 协议, baseURL, 默认模型占位}` 四个字段；除 Anthropic 外，其余全部可以是同一个「OpenAI 兼容」实现加不同的预设数据。

## 2. 各厂商信息表

字段：协议 / 默认 Base URL / 鉴权头 / `GET /models` / 流式与思考字段 / 坑。Base URL 统一写成"拼上 `/chat/completions` 即可请求"的形式（Cherry Studio 的数据里部分条目不带 `/v1`，是它内部自己拼路径，不能照抄，见第 5 节）。

### 2.1 OpenAI

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 原生（Chat Completions 与 Responses 两套；润色用 Chat Completions 即可） | [Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) 默认走 Responses；[LobeChat openai](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/openai/index.ts) 用 `https://api.openai.com/v1` |
| Base URL | `https://api.openai.com/v1` | LobeChat 同上 |
| 鉴权 | `Authorization: Bearer <key>` | [OpenAI Models API](https://developers.openai.com/api/reference/resources/models/methods/list) |
| `GET /models` | 支持，`{object:"list", data:[{id, object:"model", created, owned_by, shutdown_date?}]}` | 同上 [官方] |
| 流式 | SSE，`data: {...}` 逐块，`data: [DONE]` 收尾 | [Easydict OpenAIStreamTransport](https://github.com/tisfeng/Easydict/blob/main/Easydict/Swift/Service/OpenAI/OpenAIStreamTransport.swift)（解析 `[DONE]`） |
| 坑 | `/models` 返回含 embedding、whisper、tts、dall-e 等非对话模型，需前端过滤（LobeChat 在 `models:` 回调里做了处理，见上面 openai/index.ts） | [参考] |

### 2.2 Anthropic（唯一原生协议）

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | Anthropic Messages，`POST /v1/messages` | [Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming) |
| Base URL | `https://api.anthropic.com` | [Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) |
| 鉴权 | `x-api-key: <key>` + `anthropic-version: 2023-06-01`（两个都要，且不是 Bearer） | [Streaming 文档示例](https://platform.claude.com/docs/en/build-with-claude/streaming)、[List Models](https://platform.claude.com/docs/en/api/models/list) |
| `GET /models` | 支持，`{data:[{id, display_name, type:"model", created_at, lifecycle, max_input_tokens, max_tokens, capabilities…}], first_id, last_id, has_more}`；分页用 `limit`（默认 20，最大 1000）、`after_id`、`before_id`；默认含 `deprecated` 模型 | [List Models](https://platform.claude.com/docs/en/api/models/list) |
| 流式 | 具名 SSE 事件，见第 3 节 | 同上 |
| 坑 | 请求体必须带 `max_tokens`；system 是顶层字段而不是 message；`/models` 默认只返回 20 条，必须带 `limit` 或翻页 | [List Models](https://platform.claude.com/docs/en/api/models/list)；`max_tokens`/顶层 system 为 Messages API 通用约束 [未逐条核对原文] |

### 2.3 DeepSeek

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容；另有 Anthropic 兼容入口 `https://api.deepseek.com/anthropic` | [DeepSeek 推理模型指南](https://api-docs.deepseek.com/guides/reasoning_model)、[Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) |
| Base URL | `https://api.deepseek.com`（文档示例直接请求 `/chat/completions`，不带 `/v1`；带 `/v1` 也被 Easydict 使用：`https://api.deepseek.com/v1/chat/completions`） | [官方指南](https://api-docs.deepseek.com/guides/reasoning_model)、[Easydict DeepSeekService](https://github.com/tisfeng/Easydict/blob/main/Easydict/Swift/Service/DeepSeek/DeepSeekService.swift) |
| 鉴权 | `Authorization: Bearer <key>` | Easydict DeepSeekService [参考] |
| `GET /models` | 支持，路径 `GET /models`（Easydict 用 `https://api.deepseek.com/models`）；返回 `{object:"list", data:[{id, object:"model", owned_by, name, context_window, max_output_tokens, input_modalities, output_modalities, effort…}]}` | [List Models](https://api-docs.deepseek.com/api/list-models)、Easydict [官方+参考] |
| 流式 | `delta.content`；思考模型多出 `delta.reasoning_content`，在正文前输出；`data: [DONE]` 收尾；`stream_options.include_usage` 必须配合 `stream:true` 否则 400 | [Create Chat Completion](https://api-docs.deepseek.com/api/create-chat-completion) |
| 坑 | 关闭/开启思考用顶层 `thinking:{type:"enabled"/"disabled"}`，另有 `reasoning_effort`；这不是 OpenAI 标准字段 | [官方指南](https://api-docs.deepseek.com/guides/reasoning_model) |

### 2.4 阿里百炼 / Qwen（DashScope）

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容（另有 Responses、Anthropic 入口） | [Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) |
| Base URL | 通用旧域名 `https://dashscope.aliyuncs.com/compatible-mode/v1`（Cherry、LobeChat 都用它）；官方现推荐按区域的工作空间域名 `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`（另有 us-east-1、ap-southeast-1、ap-northeast-1），旧域名仍可用 | [百炼 OpenAI 兼容文档](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)、[LobeChat qwen](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/qwen/index.ts) |
| 鉴权 | `Authorization: Bearer <key>`；**Key 与地域绑定**，跨地域用会返回 401 `invalid_api_key`（官方说明这是地域不匹配而非 Key 无效） | [百炼 OpenAI 兼容文档](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope) |
| `GET /models` | **[未证实]** 官方兼容文档未提及；LobeChat 的 qwen 预设有自己的模型列表 | 同上 |
| 流式 | 思考内容在 `delta.reasoning_content`，先思考后输出 `content`；`include_usage` 时最后一块 `choices` 为空数组只带 usage | [百炼深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking) |
| 坑 | `enable_thinking` 是百炼扩展字段，非 OpenAI 标准；部分开源版（如 qwen3.5 系列）**只支持流式**，非流式调用会报错；不同模型默认是否思考不同（Qwen3.5/3.6/3.7/3.8 默认开，Qwen-Plus/Flash 默认关）；文档写明 `tools` 与 `stream=True` 不能同用（润色不用 tools，无影响） | [百炼深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking)、[兼容文档](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope) |

### 2.5 Moonshot / Kimi

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容（另有 `/anthropic` 入口） | [Kimi Chat API](https://platform.kimi.com/docs/api/chat)、[Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) |
| Base URL | 中国站 `https://api.moonshot.cn/v1`；国际站 `https://api.moonshot.ai/v1`（Cherry 分成 `moonshot` 与 `moonshot-global` 两个条目） | 同上 |
| 鉴权 | `Authorization: Bearer <key>`；**kimi.com 与 kimi.ai 两个平台的 Key 不能互用** | [Kimi List Models](https://platform.kimi.com/docs/api/list-models) |
| `GET /models` | 支持，`{object:"list", data:[{id, object, created, owned_by, context_length, supports_image_in, supports_video_in, supports_reasoning}]}`（比 OpenAI 多出能力字段） | [Kimi List Models](https://platform.kimi.com/docs/api/list-models) |
| 流式 | `data:` JSON 块，`include_usage` 时最后有 usage 块，以 `data: [DONE]` 收尾；官方提醒流被中断时 usage 块可能缺失；非流式 `message.reasoning_content` 仅在思考开启时返回，**流式块里的字段格式官方页面没给出** | [Kimi Chat API](https://platform.kimi.com/docs/api/chat) |
| 坑 | `max_tokens` 已弃用，改用 `max_completion_tokens`；思考控制因模型而异（k2.6 用 `thinking.type`，k3 用顶层 `reasoning_effort` 且始终思考）；多轮对话官方要求原样回传 `reasoning_content`，LobeChat 已因此处理过"thinking 开启但 tool call 消息缺 `reasoning_content`"报错 | [Kimi Chat API](https://platform.kimi.com/docs/api/chat)、[LobeChat moonshot](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/moonshot/index.ts) |

### 2.6 智谱 GLM

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容风格（官方自称"标准 HTTP API"，未声明兼容；Cherry、LobeChat、Easydict 都按 OpenAI 格式接入） | [智谱 API 介绍](https://docs.bigmodel.cn/cn/api/introduction)；[Easydict ZhipuService](https://github.com/tisfeng/Easydict/blob/main/Easydict/Swift/Service/Zhipu/ZhipuService.swift)、[LobeChat zhipu](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/zhipu/index.ts) |
| Base URL | `https://open.bigmodel.cn/api/paas/v4`（**版本段是 `v4`，不是 `v1`**）；Coding Plan 用户有单独的 Coding 端点（官方页面另有链接，本次未展开） | [智谱 API 介绍](https://docs.bigmodel.cn/cn/api/introduction) |
| 鉴权 | `Authorization: Bearer <key>` | 同上 |
| `GET /models` | **[未证实]** 官方介绍页未涉及；Cherry 数据中智谱无 `modelsApiUrls` | 同上 |
| 流式 | `delta` 里可能出现 `reasoning_content`（思考）或 `content`（正文）；官方示例会跳过 `choices` 为空的块 | [智谱深度思考](https://docs.bigmodel.cn/cn/guide/capabilities/thinking) |
| 坑 | `thinking.type` 取 `enabled`（默认）/`disabled`；GLM-5.3 系列传 `disabled` 会报错；`reasoning_effort` 仅 GLM-5.2 及以上支持 | [智谱深度思考](https://docs.bigmodel.cn/cn/guide/capabilities/thinking) |

### 2.7 火山方舟 / 豆包

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容 | [方舟对话 API](https://www.volcengine.com/docs/82379/1494384)、[Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) |
| Base URL | `https://ark.cn-beijing.volces.com/api/v3`（**版本段是 `v3`**） | [LobeChat volcengine](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/volcengine/index.ts)、方舟对话 API |
| 鉴权 | `Authorization: Bearer <API Key>` | 方舟对话 API [官方，经搜索摘要，未读到原文页面，**[未证实]** 原文措辞] |
| `GET /models` | **[未证实]** 数据面 `/api/v3` 下没有找到官方的模型列表接口；官方模型列表属于控制面 OpenAPI（不同域名与签名机制） | 同上 |
| 流式 | `delta.reasoning_content`；部分新模型在思考结束、正文开始前会多一条 `content` 与 `reasoning_content` 都为空、只带 `encrypted_content` 的块，解析时要容忍空块 | [方舟对话 API](https://www.volcengine.com/docs/82379/1494384) |
| 坑 | **`model` 字段可以填模型 ID，也可以填推理接入点 ID（`ep-xxxx`）**，官方推荐后者；因此不能指望 `/models` 给出可选项，必须允许用户手填 `model`。`thinking.type` 取值只接受 Ark 认可的几种，LobeChat 专门做了过滤 | [创建模型单元](https://www.volcengine.com/docs/82379/2122001)、[LobeChat volcengine](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/volcengine/index.ts) |

### 2.8 硅基流动 SiliconFlow

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容（另有 Anthropic 入口） | [SiliconFlow Chat Completions](https://docs.siliconflow.cn/cn/api-reference/chat-completions/chat-completions) |
| Base URL | `https://api.siliconflow.cn/v1`（国际站域名本次未核对） | 同上、[LobeChat siliconcloud](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/siliconcloud/index.ts) |
| 鉴权 | `Authorization: Bearer <key>` | 同上 |
| `GET /models` | 支持，OpenAI 风格 `{object:"list", data:[{id, object, created, owned_by}]}`；可选查询参数 `type`（text/image/audio/video）与 `sub_type`（chat/embedding/reranker/…），**应带 `?sub_type=chat` 过滤** | [SiliconFlow List Models](https://docs.siliconflow.cn/docs/api/models-get)（经搜索摘要） |
| 流式 | 以 `data: [DONE]` 收尾；思考模型的 `reasoning_content` 与 `content` 并列 | [SiliconFlow Chat Completions](https://docs.siliconflow.cn/cn/api-reference/chat-completions/chat-completions) |
| 坑 | 模型 ID 带组织前缀（如 `deepseek-ai/DeepSeek-V4-Flash`，含 `/`）；`enable_thinking`（布尔）+ `thinking_budget`（128–32768）是扩展字段；LobeChat 对余额不足/未实名 Key 访问受限模型的报错做了专门提示 | [SiliconFlow List Models](https://docs.siliconflow.cn/docs/api/models-get)、[LobeChat siliconcloud](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/siliconcloud/index.ts) |

### 2.9 OpenRouter

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容（另有 Anthropic Messages 入口） | [OpenRouter API Overview](https://openrouter.ai/docs/api-reference/overview) |
| Base URL | `https://openrouter.ai/api/v1` | 同上 |
| 鉴权 | `Authorization: Bearer <key>`；可选头 `HTTP-Referer`、`X-OpenRouter-Title`（也接受 `X-Title`）用于应用归因，**非必填** | 同上 |
| `GET /models` | 支持，返回 `{data:[{id, canonical_slug, name, created, pricing, context_length, architecture, top_provider, supported_parameters, …}], total_count, links.next}`；规范里该接口声明需 Bearer 认证，但 403 示例提到 management key，**实际是否可匿名调用 [未证实]** | [OpenRouter Models API](https://openrouter.ai/docs/api-reference/models/get-models) |
| 流式 | 见第 3 节：会插入 `: OPENROUTER PROCESSING` 注释行；错误可能在 200 之后以流内事件出现 | [OpenRouter Streaming](https://openrouter.ai/docs/api-reference/streaming) |
| 坑 | 模型数量极大（数百），选择器必须支持搜索；ID 形如 `vendor/model`；思考字段名官方 Overview 页没有定义，**[未证实]** 需实测 | [OpenRouter Models API](https://openrouter.ai/docs/api-reference/models/get-models) |

### 2.10 Gemini（OpenAI 兼容端点）

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容（官方标注 beta）；原生协议不在首版范围（见 #1 Out of scope） | [Gemini OpenAI 兼容](https://ai.google.dev/gemini-api/docs/openai) |
| Base URL | `https://generativelanguage.googleapis.com/v1beta/openai/` | 同上 |
| 鉴权 | `Authorization: Bearer <Gemini API key>`（兼容端点接受 Bearer） | 同上 |
| `GET /models` | 支持，`GET .../openai/models`，另有 `.../openai/models/{id}` | 同上；返回 ID 是否带 `models/` 前缀 **[未证实]**（官方示例用裸 ID `gemini-…`） |
| 流式 | `stream=True`，`chunk.choices[0].delta`；`stream_options.include_usage` 可用 | 同上 |
| 坑 | 官方明确：reasoning 与 `thinking_level`/`thinking_budget` 不能同用；2.5 Pro 与 3 系列**无法关闭思考**；文档中有一个示例的 URL 没有 `openai/` 段，容易抄错 | 同上 |

### 2.11 Ollama（本地）

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容（`/v1`），另有原生 `/api/chat` | [Ollama OpenAI 兼容](https://docs.ollama.com/api/openai-compatibility) |
| Base URL | 本地 `http://localhost:11434/v1/`；云端 `https://ollama.com/v1` | 同上 |
| 鉴权 | 本地**不需要 Key**（客户端要求占位值，Ollama 忽略）；云端用 `OLLAMA_API_KEY` | 同上；Cherry 标记 `authOptional: true` [参考] |
| `GET /models` | 支持 `/v1/models`；`created` 是模型最后修改时间，`owned_by` 默认 `"library"`；只列**已拉取**的本地模型 | 同上 |
| 流式 | 支持，含 `include_usage` | 同上 |
| 坑 | 兼容层不支持 `logprobs`、`tool_choice`、`logit_bias`、`user`、`n`；**无法通过 OpenAI 接口设置上下文长度**（需 Modelfile 的 `num_ctx`），长文本润色可能被默认窗口截断；思考控制用 `reasoning_effort` | 同上 |

### 2.12 LM Studio（本地）

| 项 | 内容 | 出处 |
|---|---|---|
| 协议 | OpenAI 兼容 | [LM Studio OpenAI 兼容](https://lmstudio.ai/docs/developer/openai-compat) |
| Base URL | `http://localhost:1234/v1`（LobeChat 写 `127.0.0.1`） | 同上、[LobeChat lmstudio](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/lmstudio/index.ts) |
| 鉴权 | 官方兼容页**未涉及**；Cherry 标记 `authOptional: true`，即 Key 可留空 [参考] | [Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json) |
| `GET /models` | 支持 `GET /v1/models`，LobeChat 直接用 `client.models.list()` 的 `data` | 官方 + LobeChat [官方+参考] |
| 流式 | 官方兼容页未涉及；按 OpenAI 格式处理 | — |
| 坑 | 服务需用户手动启动；列出的是已下载模型，未加载的模型调用时可能触发加载而首包很慢 **[未证实]** | — |

## 3. 流式格式的坑

### 3.1 OpenAI 兼容流（11 家共用解析器）

- **帧格式**：每行 `data: <json>`，空行分隔；收尾 `data: [DONE]`（不是 JSON，必须先判断再解析）。Easydict 的 `OpenAIStreamTransport` 对 `[DONE]` 和空 payload 都做了短路：<https://github.com/tisfeng/Easydict/blob/main/Easydict/Swift/Service/OpenAI/OpenAIStreamTransport.swift>。
- **SSE 注释行**：OpenRouter 会发 `: OPENROUTER PROCESSING` 保活，官方要求"先跳过以 `:` 开头的行再 `JSON.parse`"（[OpenRouter Streaming](https://openrouter.ai/docs/api-reference/streaming)）。解析器应一律忽略 `:` 开头的行，并容忍空行。
- **usage 块**：`stream_options.include_usage:true` 时最后一块 `choices` 为空数组，只带 `usage`（[百炼深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking)、[智谱深度思考](https://docs.bigmodel.cn/cn/guide/capabilities/thinking) 示例都要求跳过空 `choices`）。DeepSeek 要求它必须与 `stream:true` 同用，否则 400（[DeepSeek Create Chat Completion](https://api-docs.deepseek.com/api/create-chat-completion)）。OpenRouter 的 usage 块会带一个空 `delta` 的 choice 并重复 `finish_reason`，不是第二个结束信号（[OpenRouter Streaming](https://openrouter.ai/docs/api-reference/streaming)）。润色不需要 usage，**建议不发 `stream_options`**，少一类兼容问题。
- **流中错误（200 之后）**：OpenRouter 错误以流内事件到达，顶层带 `error` 字段且 `finish_reason:"error"`，可能是流里唯一的事件（[OpenRouter Streaming](https://openrouter.ai/docs/api-reference/streaming)）。其他厂商未见同类说明，但解析器应统一：任何块出现顶层 `error` 即判失败。
- **思考内容字段**：
  - `delta.reasoning_content`：DeepSeek、百炼、智谱、火山方舟、SiliconFlow、Kimi（非流式确认，流式字段名官方页未给出）。
  - OpenRouter：官方 Overview 页未定义思考字段，**[未证实]**。
  - Ollama：`reasoning_effort` 控制，输出字段**[未证实]**。
  - 润色只取 `delta.content`；`reasoning_content` 到达时丢弃。注意某些模型在思考阶段 `content` 为 `null` 或缺失，不能对其做强制解包（方舟还会插入两者皆空的块）。
- **回传 `reasoning_content`**：Kimi 官方要求多轮时原样回传；润色是单轮，不涉及。
- **关闭思考的参数完全不统一**，对比如下（润色希望尽量关闭以降低首字延迟）：

| 厂商 | 关闭思考 | 出处 |
|---|---|---|
| DeepSeek / 智谱 / Kimi k2.6 / 火山 | 顶层 `thinking:{type:"disabled"}` | 各自官方页（见第 2 节）、Cherry `reasoningFormat.wire.off` |
| 百炼 | `enable_thinking:false`（扩展字段） | [百炼深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking) |
| SiliconFlow | `enable_thinking:false` | [SiliconFlow Chat Completions](https://docs.siliconflow.cn/cn/api-reference/chat-completions/chat-completions) |
| OpenRouter | `reasoning` 对象（LobeChat 的实现） | [LobeChat openrouter](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/openrouter/index.ts) |
| Gemini | `reasoning_effort:"none"` 仅 2.5 可用，2.5 Pro / 3 系列不可关 | [Gemini OpenAI 兼容](https://ai.google.dev/gemini-api/docs/openai) |
| Ollama | `reasoning_effort:"none"` | [Ollama OpenAI 兼容](https://docs.ollama.com/api/openai-compatibility) |
| Kimi k3 / GLM-5.3 | 不可关（始终思考） | [Kimi Chat API](https://platform.kimi.com/docs/api/chat)、[智谱深度思考](https://docs.bigmodel.cn/cn/guide/capabilities/thinking) |

  **含义**：首版不要尝试"替用户关思考"。额外参数一律交给一个可选的「额外请求体 JSON」字段，由用户按厂商文档自己填。

### 3.2 Anthropic 流

出处：[Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming)。

- 帧格式是**具名事件**：`event: <name>` + `data: <json>`，data 内也有 `type` 字段。**没有 `[DONE]`**，以 `message_stop` 事件结束。
- 事件顺序：`message_start` → （每个内容块）`content_block_start` → 若干 `content_block_delta` → `content_block_stop` → `message_delta`（含 stop_reason、usage）→ `message_stop`。
- `ping` 事件可能穿插在任何位置，必须忽略。
- `error` 事件可能出现在流中（如 `overloaded_error`，对应非流式的 HTTP 529），格式 `{"type":"error","error":{"type":…,"message":…}}`，应当向用户显示。
- 文本只取 `content_block_delta` 里 `delta.type == "text_delta"` 的 `delta.text`；其他 delta 类型包括 `input_json_delta`（工具调用）、`thinking_delta`、`signature_delta`（思考块结束前发送），一律忽略。官方提醒可能新增事件类型，应忽略未知事件（文档"Other events"一节）。
- 与 OpenAI 流的差别一眼可见：思考内容是独立内容块（`thinking_delta`），不是 `reasoning_content` 字段。

## 4. `GET /models` 的坑

| 问题 | 涉及厂商 | 出处 |
|---|---|---|
| **返回形状不统一**：OpenAI 系是 `{data:[{id}]}`；Anthropic 是 `{data, first_id, last_id, has_more}` 且按 `limit` 分页；OpenRouter 是 `{data, total_count, links.next}` | 全部 | 见第 2 节各表 |
| **鉴权头不同**：Anthropic 必须 `x-api-key` + `anthropic-version`，其余 Bearer | Anthropic | [List Models](https://platform.claude.com/docs/en/api/models/list) |
| **分页**：Anthropic 默认只回 20 条（最大 1000）；OpenRouter 有 `links.next` | Anthropic、OpenRouter | 同上、[OpenRouter Models API](https://openrouter.ai/docs/api-reference/models/get-models) |
| **混杂非对话模型**：OpenAI 含 embedding/语音/图像；SiliconFlow 需 `?sub_type=chat` | OpenAI、SiliconFlow | [LobeChat openai](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/openai/index.ts)、[SiliconFlow List Models](https://docs.siliconflow.cn/docs/api/models-get) |
| **没有可用的数据面接口 / 未证实**：火山方舟、百炼、智谱 | 火山、百炼、智谱 | 见第 2 节 |
| **火山 `model` 可为接入点 ID**：列表给不出用户真正要填的 `ep-xxx` | 火山 | [创建模型单元](https://www.volcengine.com/docs/82379/2122001) |
| **Key 或地域不匹配会让 `/models` 也 401**：百炼（Key 与地域绑定）、Kimi（kimi.com 与 kimi.ai Key 不互通） | 百炼、Kimi | [百炼兼容文档](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)、[Kimi List Models](https://platform.kimi.com/docs/api/list-models) |
| **只列已安装模型**：Ollama、LM Studio 的列表取决于本机，不是云端目录 | Ollama、LM Studio | [Ollama](https://docs.ollama.com/api/openai-compatibility) |
| **数量巨大**：OpenRouter 数百个，选择器需可搜索 | OpenRouter | [OpenRouter Models API](https://openrouter.ai/docs/api-reference/models/get-models) |
| **Base URL 拼接陷阱**：版本段不统一（`v1` / `v3` / `v4` / `v1beta/openai` / 无版本），且 DeepSeek 带不带 `/v1` 都行。Cherry 数据里 DeepSeek、Moonshot、LM Studio 的 baseUrl 都不带 `/v1`，是其内部再拼路径；LobeChat 对 DeepSeek/Moonshot 还有专门的 `normalize…BaseURL` 去掉用户误填的路径后缀 | 全部 | [Cherry providers.json](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json)、[LobeChat deepseek](https://github.com/lobehub/lobe-chat/blob/main/packages/model-runtime/src/providers/deepseek/index.ts) |

**建议**：`/models` 只当作"可选的填充输入框候选"，失败（404、401、解析不出）一律静默降级为手填；模型输入框始终允许自由文本。

## 5. 参考项目的做法（对照）

- **Cherry Studio**：provider 数据外置为 [`providers.json`](https://github.com/CherryHQ/cherry-studio/blob/main/packages/provider-registry/data/providers.json)，每家有 `endpointConfigs`（按协议 `openai-chat-completions` / `anthropic-messages` / `openai-responses` / `ollama-chat` 分别配 `baseUrl`）、`authOptional`、`availableInEditions`、官网/文档/Key 申请链接。几乎每家同时提供 OpenAI 与 Anthropic 两个入口。思考开关用 `reasoningFormat.wire` 描述每家的请求体差异。启示：**预设 = 纯数据**。
- **LobeChat**：每家一个 `model-runtime/src/providers/<name>/index.ts`，在 OpenAI 兼容运行时上叠加 `baseURL` 与 `handlePayload`（重写请求体以适配思考字段）、`models` 回调（自定义列表解析）。启示：厂商差异集中在"改请求体"和"解析模型列表"两处。
- **Easydict**：`OpenAIService`、`DeepSeekService`、`ZhipuService`、`GeminiService`、`CustomOpenAIService` 等共用 `BaseOpenAIService` 与 `OpenAIStreamTransport`：Bearer 头，另外同时发一个 `api-key` 头兼容 Azure（<https://github.com/tisfeng/Easydict/blob/main/Easydict/Swift/Service/OpenAI/OpenAIStreamTransport.swift>）。其 Gemini 用的是 Google 原生 SDK 而不是兼容端点。启示：一个流式传输类加若干很薄的子类即可覆盖主流厂商，且存在一个"自定义 OpenAI"通用入口。

## 6. 最小预设清单建议

### 6.1 协议实现：只写两个

1. **OpenAI 兼容**（`POST {base}/chat/completions`，Bearer，SSE `data:`/`[DONE]`，只取 `delta.content`）。
2. **Anthropic 原生**（`POST {base}/v1/messages`，`x-api-key` + `anthropic-version`，具名事件，只取 `text_delta`）。

### 6.2 预设（数据条目，内置）

| # | 预设 | 协议 | 默认 Base URL | Key |
|---|---|---|---|---|
| 1 | OpenAI | OpenAI 兼容 | `https://api.openai.com/v1` | 必填 |
| 2 | Anthropic | Anthropic 原生 | `https://api.anthropic.com` | 必填 |
| 3 | DeepSeek | OpenAI 兼容 | `https://api.deepseek.com` | 必填 |
| 4 | 阿里百炼 | OpenAI 兼容 | `https://dashscope.aliyuncs.com/compatible-mode/v1`（提示：Key 与地域绑定） | 必填 |
| 5 | Moonshot / Kimi | OpenAI 兼容 | `https://api.moonshot.cn/v1`（国际站 `https://api.moonshot.ai/v1` 作备选提示） | 必填 |
| 6 | 智谱 GLM | OpenAI 兼容 | `https://open.bigmodel.cn/api/paas/v4` | 必填 |
| 7 | 火山方舟 | OpenAI 兼容 | `https://ark.cn-beijing.volces.com/api/v3`（`model` 填模型 ID 或 `ep-xxx`） | 必填 |
| 8 | 硅基流动 | OpenAI 兼容 | `https://api.siliconflow.cn/v1` | 必填 |
| 9 | OpenRouter | OpenAI 兼容 | `https://openrouter.ai/api/v1` | 必填 |
| 10 | Gemini | OpenAI 兼容 | `https://generativelanguage.googleapis.com/v1beta/openai/` | 必填 |
| 11 | Ollama | OpenAI 兼容 | `http://localhost:11434/v1` | 可空 |
| 12 | LM Studio | OpenAI 兼容 | `http://localhost:1234/v1` | 可空 |
| 13 | 自定义（OpenAI 兼容） | OpenAI 兼容 | 用户填写 | 可空 |

### 6.3 哪些可以合并为通用「OpenAI 兼容（自定义）」

**除 Anthropic 以外的 11 家在协议层完全相同**，代码里只需要一个 OpenAI 兼容实现。是否保留为独立预设，只是"免去用户查 URL"的便利，不增加代码：

- **必须保留为独立实现**：Anthropic（协议不同）。
- **建议保留为预设条目（零额外代码，仅数据）**：OpenAI、DeepSeek、百炼、Kimi、智谱、火山、硅基流动、OpenRouter、Gemini、Ollama、LM Studio。理由是 URL 不好记（`paas/v4`、`api/v3`、`v1beta/openai/`）。
- **可以直接只留「自定义」而不做内置预设的，按奥卡姆剃刀从低到高优先**：LM Studio、硅基流动、OpenRouter（用户自己粘贴 URL 即可，没有特殊握手）。若要进一步精简首版，**最小可行集 = Anthropic + OpenAI 兼容（自定义）+ 数据预设 OpenAI / DeepSeek / 百炼 / Kimi / 智谱 / 火山 / Ollama**。
- **Gemini 的取舍**：使用兼容端点、无需单独代码，但思考不可关（2.5 Pro / 3 系列）会拖慢首字延迟；列为预设可以，但不要承诺低延迟。

### 6.4 首版实现取舍（给 #10 设计文档参考）

1. 预设做成 JSON 数据（名称、协议、baseURL、`keyOptional`、提示文案），不要给每家写子类。参考 Cherry 的 `providers.json`。
2. 一个可选的「额外请求体 JSON」字段，用于用户自行加 `thinking` / `enable_thinking` 等方言参数（第 3.1 节表格）。
3. `/models` 仅作可选的候选填充，失败静默降级；模型名始终可手填（火山 `ep-xxx`、OpenRouter 数百个模型都靠这个兜底）。
4. 流式解析统一规则：忽略 `:` 注释行与空行；`[DONE]` 或 `message_stop` 结束；任一帧出现顶层 `error` 则报错；只取 `delta.content` / `text_delta`；不发 `stream_options`。
5. Base URL 拼接规则固定为"用户填的 URL 去掉末尾 `/` 后追加 `/chat/completions`"，不做版本段猜测；预设里直接给出完整含版本段的值，并在输入框下方放示例。

## 7. 未证实项（实现前需实测，需要真实 Key，本次不做）

- 百炼、智谱、火山方舟的 `GET /models` 数据面是否存在。
- Kimi、OpenRouter、Ollama 流式块里思考内容的字段名。
- OpenRouter `/models` 是否可匿名调用。
- Gemini 兼容端点 `/models` 返回的 `id` 是否带 `models/` 前缀。
- 火山方舟 Bearer 鉴权的官方原文措辞（本次只取得搜索摘要，其文档页面抓取被重定向/404）。
- 硅基流动国际站域名；智谱 Coding Plan 端点；LM Studio 的 Key 校验行为。
- Anthropic 的 `max_tokens` 必填与顶层 `system` 属 Messages API 通用约束，本次没有逐条回读原文。

## 8. 本次调研的局限

- 官方文档经 WebFetch 的小模型摘要读取，部分页面（OpenAI 平台页 403、火山方舟、硅基流动一个 URL）无法取得原文，已在对应条目标注。
- 参考项目源码来自各仓库 `main` 分支，版本会变；文中链接指向分支而非固定 commit。
- 文中出现的具体模型名（如 `kimi-k3`、`GLM-5.3`）取自官方文档当日内容，不作为预设默认值。
