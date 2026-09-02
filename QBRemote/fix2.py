import io
p = 'TorrentDetailView.swift'
s = io.open(p, encoding='utf-8').read()
old = '''                            Spacer()
                            Button {
                                selectAllFiles()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
                                    Text(allSelected ? "全不选" : "全选下载")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundColor(.green)
                            }
                            Spacer()'''
new = '''                            Spacer()'''
if old in s:
    s = s.replace(old, new)
    io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
    print('REMOVED')
else:
    print('OLD NOT FOUND')
