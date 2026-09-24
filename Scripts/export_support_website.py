#!/usr/bin/env python3
"""AI CONTEXT: Export SupportContent to website HTML; never deploy.
Swift evaluates the real guide model with a display-only Color shim. Keep every
SupportBlock case covered. Website release notices remain explicit until 1.7 ships.
Usage: python3 Scripts/export_support_website.py /path/to/kevmarl-site
"""
import html, json, re, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
site = Path(sys.argv[1])
source = (root/'Views/SupportContent.swift').read_text().replace('import SwiftUI', '''import Foundation
struct Color {
 init(white: Double) {} 
 init(red: Double, green: Double, blue: Double) {}
 static let purple = Color(white: 0)
}''')
source += '''
func block(_ b: SupportBlock) -> [String: Any] {
 switch b {
 case .paragraph(let s): return ["kind":"p", "text":s]
 case .heading(let s): return ["kind":"h3", "text":s]
 case .bullets(let a): return ["kind":"ul", "items":a]
 case .steps(let a): return ["kind":"ol", "items":a]
 case .callout(_, let s): return ["kind":"aside", "text":s]
 case .table(let h, let r): return ["kind":"table", "headers":h ?? [], "rows":r]
 case .pills(let p): return ["kind":"ul", "items":p.map { $0.label }]
 case .swipe(let rt, let r, let lt, let l): return ["kind":"ul", "items":r.map { rt + ": " + $0.label + " — " + $0.detail } + l.map { lt + ": " + $0.label + " — " + $0.detail }]
 case .link(let label, let url): return ["kind":"link", "text":label, "url":url]
 }
}
let data = SupportGuide.sections.map { ["id":$0.id, "title":$0.title, "blocks":$0.blocks.map(block)] as [String:Any] }
print(String(data: try JSONSerialization.data(withJSONObject:data, options:[.sortedKeys]), encoding:.utf8)!)
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'export.swift';p.write_text(source)
 sections=json.loads(subprocess.check_output(['swift',str(p)],text=True))
def text(s):
 return re.sub(r'\*\*(.*?)\*\*',r'<strong>\1</strong>',html.escape(s)).replace('\n','<br>')
def render(b):
 k=b['kind']
 if k == 'h3' and b['text'] in ['Playback Speed','Trim Silence','Vocal Boost','Shared Listening']:
  anchor={'Playback Speed':'speed','Trim Silence':'trim-silence','Vocal Boost':'vocal-boost','Shared Listening':'shared-listening'}[b['text']]
  return '<h3 id="'+anchor+'">'+text(b['text'])+'</h3>'
 if k in ['p','h3','aside']:return f'<{k}>{text(b["text"])}</{k}>'
 if k in ['ul','ol']:return '<'+k+'>'+''.join('<li>'+text(i)+'</li>' for i in b['items'])+'</'+k+'>'
 if k=='link':return '<p><a href="'+html.escape(b['url'],quote=True)+'">'+text(b['text'])+'</a></p>'
 if k=='table':
  h='<thead><tr>'+''.join('<th>'+text(x)+'</th>' for x in b['headers'])+'</tr></thead>' if b['headers'] else ''
  return '<table>'+h+'<tbody>'+''.join('<tr>'+''.join('<td>'+text(x)+'</td>' for x in r)+'</tr>' for r in b['rows'])+'</tbody></table>'
 raise ValueError(k)
p=site/'support.html';page=p.read_text()
start=page.find('<nav aria-label="Guide topics">')
if start < 0: start=page.index('    <section class="doc-section" id="getting-started">')
end=page.index('  </main>',start)
body='''    <!-- GENERATED from Autohop/Views/SupportContent.swift. Run export_support_website.py. -->
    <aside class="callout"><strong>Version coverage:</strong> This guide includes the released iOS-family 1.6.1 app and clearly labelled previews of Version 1.7, which is not yet released. Version 1.7 instructions and Play Instant’s two-minute protection apply to that upcoming build. Earlier layouts and button labels may differ. Apple TV releases separately.</aside>
'''
body+='\n'.join('    <section class="doc-section" id="'+s['id']+'"><h2>'+text(s['title'])+'</h2>\n'+'\n'.join(render(b) for b in s['blocks'])+'\n</section>' for s in sections)
# Preserve existing navigation IDs; add new topics to the main content index.
body='<nav aria-label="Guide topics">'+''.join('<a href="#'+s['id']+'">'+text(s['title'])+'</a> · ' for s in sections)+'</nav>\n'+body
p.write_text(page[:start]+body+'\n'+page[end:])
print(f'Exported {len(sections)} sections to {p}')
