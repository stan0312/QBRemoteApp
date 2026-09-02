import io
p = 'QBClient.swift'
s = io.open(p, encoding='utf-8').read()
old = '''        let params = [
            "hash": hash,
            "id": ids.map(String.init).joined(separator: ","),
            "priority": "\\(priority)"
        ]
        _ = try await postForm("/api/v2/torrents/filePrio", params: params)'''
new = '''        // 注意：qB filePrio 要求多个文件 id 用 | 分隔（逗号会返回 400）
        let params = [
            "hash": hash,
            "id": ids.map(String.init).joined(separator: "|"),
            "priority": "\\(priority)"
        ]
        _ = try await postForm("/api/v2/torrents/filePrio", params: params)'''
if old in s:
    s = s.replace(old, new)
    io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
    print('REPLACED')
else:
    print('OLD NOT FOUND')
    import re
    m = re.search(r'joined\(separator: ",\"\)', s)
    print('sep comma found:', bool(m))
