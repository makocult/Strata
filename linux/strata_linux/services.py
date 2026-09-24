"""Linux persistence and OpenAI-compatible AI services for Strata."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any


def data_dir() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "Strata"


def _atomic(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(raw); handle.flush(); os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        try: os.unlink(name)
        except FileNotFoundError: pass


class Library:
    def __init__(self, path: Path | str | None = None):
        self.path = Path(path) if path is not None else data_dir() / "materials.json"
        self.materials: list[dict[str, str]] = []
        self.load_error = ""
        self._blocked = False
        self.reload()

    def reload(self) -> None:
        if not self.path.exists():
            self.materials, self.load_error, self._blocked = [], "", False; return
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(value, list) or any(not isinstance(x, dict) for x in value): raise ValueError
            checked = []
            for item in value:
                if not all(isinstance(item.get(k), str) for k in ("id", "title", "content")): raise ValueError
                uuid.UUID(item["id"]); checked.append({k: item[k] for k in ("id", "title", "content")})
            self.materials, self.load_error, self._blocked = checked, "", False
        except Exception:
            self.load_error, self._blocked = "素材库读取失败，文件可能已损坏或不可访问。", True

    def matching(self, query: str) -> list[dict[str, str]]:
        if not query: return list(self.materials)
        q = query.casefold()
        return [x for x in self.materials if q in x["title"].casefold() or q in x["content"].casefold()]

    def save(self, title: str, content: str, id: str | None = None) -> dict[str, str]:
        if not title.strip(): raise ValueError("标题不能为空。")
        if not content.strip(): raise ValueError("内容不能为空。")
        if self._blocked: raise RuntimeError("素材库当前无法写入，请先重新加载。")
        candidate = [dict(x) for x in self.materials]
        if id is None: item = {"id": str(uuid.uuid4()), "title": title, "content": content}; candidate.insert(0, item)
        else:
            try: index = next(i for i, x in enumerate(candidate) if x["id"] == id)
            except StopIteration: raise KeyError("未找到指定素材。")
            item = {"id": id, "title": title, "content": content}; candidate[index] = item
        try: _atomic(self.path, json.dumps(candidate, ensure_ascii=False, indent=2).encode())
        except Exception as exc: raise OSError("素材库保存失败，原有内容未改变。") from exc
        self.materials = candidate; self.load_error = ""; return dict(item)

    def delete(self, id: str) -> bool:
        if self._blocked: raise RuntimeError("素材库当前无法写入，请先重新加载。")
        candidate = [x for x in self.materials if x["id"] != id]
        if len(candidate) == len(self.materials): raise KeyError("未找到指定素材。")
        try: _atomic(self.path, json.dumps(candidate, ensure_ascii=False, indent=2).encode())
        except Exception as exc: raise OSError("素材库保存失败，原有内容未改变。") from exc
        self.materials = candidate; return True


class Settings:
    defaults = {"baseURL": "https://api.openai.com/v1", "model": "", "proxyURL": ""}
    def __init__(self, path: Path | str | None = None):
        self.path = Path(path) if path is not None else data_dir() / "ai-settings.json"
        self.configuration = dict(self.defaults); self.load_error = ""; self.load()

    def load(self) -> dict[str, str]:
        try:
            if self.path.exists():
                value = json.loads(self.path.read_text(encoding="utf-8"))
                self.configuration = {k: str(value.get(k, self.defaults[k])) for k in self.defaults}
            self.load_error = ""
        except Exception: self.load_error = "设置读取失败。"
        return dict(self.configuration)

    def save(self, configuration: dict[str, str]) -> None:
        self.configuration = {k: str(configuration.get(k, self.defaults[k])) for k in self.defaults}
        _validate_config(self.configuration)
        _atomic(self.path, json.dumps(self.configuration, ensure_ascii=False, indent=2).encode())

    def key(self, base_url: str) -> str:
        result = subprocess.run(["secret-tool", "lookup", "service", "design.wisepulse.strata.ai", "account", base_url], input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if result.returncode == 0: return result.stdout.decode().rstrip("\n")
        if result.returncode in (1, 2): return ""
        raise RuntimeError("无法读取 Linux Secret Service；请检查密钥环是否已解锁。")

    def set_key(self, base_url: str, key: str) -> None:
        try:
            result = subprocess.run(["secret-tool", "store", "--label=Strata AI API key", "service", "design.wisepulse.strata.ai", "account", base_url], input=key.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        except OSError as exc: raise RuntimeError("未找到 secret-tool；请安装 libsecret-tools。") from exc
        if result.returncode != 0: raise RuntimeError("无法保存 API 密钥；请检查 Linux Secret Service 是否已解锁。")


def _validate_config(c: dict[str, str]) -> None:
    parsed = urllib.parse.urlsplit(c["baseURL"].strip())
    if parsed.scheme not in ("https", "http") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("API 基础地址无效。")
    if parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"): raise ValueError("远程 API 请使用 HTTPS。")
    if c["proxyURL"]:
        p = urllib.parse.urlsplit(c["proxyURL"])
        if p.scheme != "http" or not p.hostname or not p.port or p.username or p.password or p.path not in ("", "/") or p.query or p.fragment: raise ValueError("代理地址需为 http://主机:端口。")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None


class AIClient:
    def __init__(self, configuration: dict[str, str], key: str = ""):
        self.configuration = configuration; self.key = key
        _validate_config(configuration)

    def _request(self, resource: str, payload: dict[str, Any] | None = None) -> Any:
        c = self.configuration; base = c["baseURL"].rstrip("/") + "/" + resource
        headers = {"Accept": "application/json"}
        if self.key.strip(): headers["Authorization"] = "Bearer " + self.key.strip()
        data = json.dumps(payload).encode() if payload is not None else None
        if data is not None: headers["Content-Type"] = "application/json"
        handlers: list[Any] = [_NoRedirect()]
        if c.get("proxyURL"): handlers.append(urllib.request.ProxyHandler({"http": c["proxyURL"], "https": c["proxyURL"]}))
        else: handlers.append(urllib.request.ProxyHandler({}))
        request = urllib.request.Request(base, data=data, headers=headers, method="POST" if data else "GET")
        try:
            with urllib.request.build_opener(*handlers).open(request, timeout=180) as response:
                raw = response.read(4_000_001)
                if len(raw) > 4_000_000: raise ValueError("API 返回内容过大。")
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"HTTP {exc.code}：AI 服务请求失败。") from None
        except urllib.error.URLError as exc: raise RuntimeError("AI 服务连接失败。") from None

    def models(self) -> list[str]:
        value = self._request("models"); result = sorted({x.get("id", "") for x in value.get("data", []) if x.get("id")})
        if not result: raise ValueError("服务没有返回可用模型。")
        return result

    def _complete(self, prompt: str, instruction: str) -> dict[str, Any]:
        if not self.configuration.get("model", "").strip(): raise ValueError("请先在设置中选择模型。")
        value = self._request("chat/completions", {"model": self.configuration["model"], "stream": False, "messages": [{"role": "system", "content": instruction}, {"role": "user", "content": prompt}]})
        choice = (value.get("choices") or [None])[0]
        if not choice or choice.get("finish_reason") == "length" or choice.get("message", {}).get("refusal") is not None: raise ValueError("模型未生成有效内容。")
        content = (choice.get("message", {}).get("content") or "").strip()
        if content.startswith("```") and content.endswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        try: root = json.loads(content)
        except Exception as exc: raise ValueError("模型未返回有效的导图 JSON。") from exc
        return _tree(root)

    def generate(self, prompt: str) -> dict[str, Any]: return self._complete(prompt, "根据用户材料和要求整理完整清晰的思维导图。只返回 JSON，不要解释，不要编造信息。")
    def optimize(self, root: dict[str, Any]) -> dict[str, Any]: return self._complete(json.dumps(root, ensure_ascii=False), "将思维导图整理为工具无关的高质量提示词树。保留事实和关系，不编造；冲突标记待确认，必要缺失最多三项标记待补充。只返回 JSON。")


def _tree(value: Any, depth: int = 1, state: list[int] | None = None) -> dict[str, Any]:
    state = state or [0]; state[0] += 1
    if state[0] > 500 or depth > 12 or not isinstance(value, dict) or not isinstance(value.get("title"), str) or not value["title"].strip() or len(value["title"]) > 2000: raise ValueError("导图结构不完整或超出限制。")
    children = value.get("children", [])
    if not isinstance(children, list): raise ValueError("模型返回的子节点格式无效。")
    return {"id": str(uuid.uuid4()), "title": value["title"], "children": [_tree(x, depth + 1, state) for x in children], "isCollapsed": False}
