import io
s = io.open('MediaPreviewView.swift', encoding='utf-8').read()
lines = s.split('\n')
print('TOTAL LINES', len(lines))
for i in range(len(lines)-6, len(lines)):
    print(i+1, repr(lines[i][:80]))
