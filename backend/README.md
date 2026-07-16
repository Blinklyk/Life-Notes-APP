# Life Notes AI Backend

这是随心记的最小 AI 代理，只负责将结构化文字素材整理为随心日记。它不接收图片、音频、媒体二进制或客户端文件路径，也不承担云同步。

上游使用 DeepSeek Chat Completions 协议：服务向 `DEEPSEEK_BASE_URL` 追加 `/chat/completions`，默认模型为 `deepseek-v4-pro`。API key、base URL 和模型名只能通过后端环境变量或 secret 注入，客户端不会接触上游密钥。

## 本地运行

需要仍在安全支持期内的 Python 3.11+。容器固定使用 Python 3.12；本地建议创建虚拟环境后安装测试依赖：

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
cp .env.example .env
# 先填写 LIFE_NOTES_BEARER_TOKEN 和 DEEPSEEK_API_KEY；前者可用 openssl rand -hex 32 生成。
set -a; source .env; set +a
uvicorn life_notes_backend.main:app --host 127.0.0.1 --port 8080 --no-access-log
```

健康检查：

```bash
curl http://127.0.0.1:8080/health
```

`.env.example` 故意将两个 secret 留空；未填写、仍是常见占位值或包含非 ASCII 字符时，服务会拒绝启动。Bearer token 必须是 16–512 个可见 ASCII 字符，并与 iPhone 设置中填写的访问令牌完全一致。

## API 契约

`POST /v1/journals/generate` 需要 `Authorization: Bearer <token>`，请求示例：

```json
{
  "request_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "style": "natural",
  "entries": [
    {
      "text": "今天完成了第一版联调。",
      "photos": [
        {
          "annotation_text": "傍晚的天空",
          "voice_transcripts": ["回家的路上很安静。"]
        }
      ],
      "voice_transcripts": ["今天的整体语音记录。"]
    }
  ]
}
```

响应只包含生成的标题、正文和 provenance。客户端使用本地附件重新拼装照片块：

```json
{
  "request_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "title": "七月十五日",
  "body": "今天完成了第一版联调。",
  "model": "deepseek-v4-pro",
  "generator_identifier": "deepseek.chat-completions.deepseek-v4-pro"
}
```

`entries` 必须按创建时间正序发送，照片和转写也必须保持客户端的稳定顺序；照片语音转写嵌套在对应照片下。客户端会先完成本地 owner/ID 校验，再过滤全空记录、无文字的照片和空转写。后端不接收记录日期、素材 fingerprint、本地稳定 ID、本机时间、空媒体数量或媒体元数据，因此不同请求无法用本地素材 ID 关联。请求至少需要一段非空正文、图片批注或语音转写；只有未批注图片时不会让模型猜测图片内容。

所有请求对象都拒绝未知字段，因此稳定素材 ID、日期、fingerprint、`original_relative_path`、`image_base64`、`audio_path` 等字段会得到 `422 invalid_request`。文本上限按 UTF-8 字节计算，与 iPhone 保持一致。认证与限流在 body 缓冲和 JSON/Pydantic 解析前执行；请求分片数、接收时间、DeepSeek 流式响应和最终 iPhone 响应都有硬上限。日志只记录请求 ID、路径、错误类型或状态，不记录请求正文和 provider 异常消息，所有 `/v1` 响应都带 `Cache-Control: no-store`。DeepSeek 返回 408、429 或 5xx 时服务报告临时故障，iPhone 可回退本地生成；其他非 2xx 会变为 `424 provider_configuration_error`，提示检查 API key、模型名、base URL 或兼容协议，客户端不会静默回退。

DeepSeek 请求使用 `response_format: {"type":"json_object"}`，返回内容再由 Pydantic 严格校验为仅含 `title/body` 的对象。`DEEPSEEK_BASE_URL` 必须是 HTTPS API 根，可以是 `https://api.deepseek.com` 或包含 `/v1` 的兼容根；代码始终只追加一次 `/chat/completions`。

`DEEPSEEK_TIMEOUT_SECONDS` 最大为 30 秒，低于 iPhone 的 35 秒请求窗口，避免客户端已回退本地后上游仍继续生成和计费。base URL 不能包含 `?` 或 `#`，即使查询或片段为空也会拒绝启动。

## Docker

```bash
docker build --target test -t life-notes-backend:test .
docker run --rm life-notes-backend:test
docker build -t life-notes-backend .
docker run --rm -p 8080:8080 --env-file .env life-notes-backend
```

`test` stage 使用 Python 3.12 运行完整 pytest；最终 `runtime` stage 不包含测试文件和 pytest。容器使用非 root 用户运行，并内置 `/health` 健康检查。生产环境应通过 secret 注入两个密钥，在云端或 Tailscale 入口终止 HTTPS。进程内限流按 Bearer credential 生效；多副本部署时还需要在网关或共享存储层增加全局限流。

Debug 真机若直接使用 HTTP，只填写规范的局域网/Tailscale IP、`.local` 名称或完整 `device.tailnet.ts.net` 名称；普通单标签 MagicDNS、非规范数字 IPv4 和公网地址会被客户端拒绝。Release 必须使用 Tailscale Serve 或云端入口提供的 HTTPS 地址。

## 测试

```bash
pytest
```
