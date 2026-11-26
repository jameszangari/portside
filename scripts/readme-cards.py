#!/usr/bin/env python3
# Draws the README feature cards in docs/images/ (light and dark in one SVG).
# Add or edit a card() call below, then run: python3 scripts/readme-cards.py
# Text must fit the 440 pt card; check the render before committing.
import math, os, sys
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'docs', 'images')
W, H = 440, 290
STYLE = '''<style>
    .card { fill: #EAF0F6; stroke: #10283F; stroke-opacity: .14; }
    .bar { fill: #FFFFFF; fill-opacity: .9; }
    .ink { fill: #10283F; }
    .soft { fill: #10283F; fill-opacity: .16; }
    .faint { fill: #10283F; fill-opacity: .07; }
    .panel { fill: #FFFFFF; stroke: #10283F; stroke-opacity: .14; }
    .notch { fill: #0B0F14; }
    .accent { fill: #F06A42; }
    .tint { fill: #F06A42; fill-opacity: .16; }
    .green { fill: #34C759; }
    .line { stroke: #10283F; stroke-opacity: .25; fill: none; }
    .aline { stroke: #F06A42; fill: none; }
    .dash { stroke: #10283F; stroke-opacity: .35; fill: none; stroke-dasharray: 4 4; }
    .light { fill: #F4EEDF; }
    text { font-family: -apple-system, BlinkMacSystemFont, "Inter", "Helvetica Neue", sans-serif; }
    .label { font-size: 17px; font-weight: 700; fill: #10283F; }
    .hint { font-size: 12.5px; font-weight: 500; fill: #10283F; fill-opacity: .6; }
    .t { font-size: 12px; font-weight: 600; fill: #10283F; }
    .tm { font-size: 11px; font-weight: 500; fill: #10283F; fill-opacity: .55; }
    .tl { font-size: 11px; font-weight: 600; fill: #F4EEDF; }
    .key { font: 600 11.5px ui-monospace, "SF Mono", Menlo, monospace; fill: #F06A42; }
    .big { font-size: 22px; font-weight: 700; fill: #10283F; }
    @media (prefers-color-scheme: dark) {
      .card { fill: #13202E; stroke: #F4EEDF; stroke-opacity: .14; }
      .bar { fill: #1C2B3B; fill-opacity: 1; }
      .ink { fill: #F4EEDF; }
      .soft { fill: #F4EEDF; fill-opacity: .22; }
      .faint { fill: #F4EEDF; fill-opacity: .08; }
      .panel { fill: #1F3044; stroke: #F4EEDF; stroke-opacity: .14; }
      .line { stroke: #F4EEDF; stroke-opacity: .3; }
      .dash { stroke: #F4EEDF; stroke-opacity: .4; }
      .label, .t, .big { fill: #F4EEDF; }
      .hint, .tm { fill: #F4EEDF; }
    }
  </style>'''

def card(name, title, hint, desc, body, W=W, H=H, defs=''):
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">
  <title id="t">{title}</title>
  <desc id="d">{desc}</desc>
  {STYLE}
  {defs}
  <rect class="card" x="1" y="1" width="{W-2}" height="{H-2}" rx="20"/>
{body}
  <text class="label" x="24" y="{H-38}">{title}</text>
  <text class="hint" x="24" y="{H-18}">{hint}</text>
</svg>
'''
    open(os.path.join(out, name + '.svg'), 'w').write(svg)

def icon(x, y, s=34, cls='soft'):
    return f'<rect class="{cls}" x="{x}" y="{y}" width="{s}" height="{s}" rx="{s*0.24:.0f}"/>'

# Dock
b = []
b.append('<rect class="faint" x="24" y="24" width="392" height="180" rx="12"/>')
# group grid popover
b.append('<rect class="panel" x="58" y="40" width="118" height="92" rx="14"/>')
for r in range(2):
    for c in range(3):
        b.append(icon(70 + c*36, 52 + r*36, 26, 'ink' if (r, c) == (0, 0) else 'soft'))
b.append('<path class="panel" d="M108 132 l9 9 l9 -9z"/>')
b.append('<text class="tm" x="186" y="60">Group grid</text>')
# dock strip
b.append('<rect class="panel" x="40" y="150" width="360" height="52" rx="16"/>')
b.append(icon(50, 159, 34, 'ink'))
b.append('<rect class="soft" x="92" y="141" width="46" height="46" rx="11"/>')
b.append(icon(146, 159))
b.append('<circle class="green" cx="150" cy="161" r="5"/>')
b.append(icon(188, 159))
b.append('<circle class="accent" cx="218" cy="161" r="7"/><text class="tl" x="218" y="165" text-anchor="middle" font-size="9">3</text>')
b.append('<rect class="ink" x="232" y="158" width="1.5" height="36" fill-opacity=".25"/>')
b.append('<rect class="faint" x="242" y="159" width="78" height="34" rx="9"/>')
b.append('<text class="t" x="252" y="174">9:41</text><text class="tm" x="252" y="187">Thu 26</text>')
b.append('<rect class="faint" x="326" y="159" width="64" height="34" rx="9"/>')
b.append('<rect class="soft" x="334" y="172" width="40" height="10" rx="3"/><rect class="green" x="336" y="174" width="26" height="6" rx="2"/>')
for x in (67, 115):
    b.append(f'<circle class="ink" cx="{x}" cy="198" r="2"/>')
for i, (dx, rot) in enumerate(((0, -14), (6, -5), (12, 4))):
    b.append(f'<rect class="panel" x="{300+dx}" y="{60+i*22}" width="64" height="22" rx="6" transform="rotate({rot} {332+dx} {71+i*22})"/>')
    b.append(f'<rect class="soft" x="{306+dx}" y="{65+i*22}" width="12" height="12" rx="3" transform="rotate({rot} {332+dx} {71+i*22})"/>')
b.append('<text class="tm" x="296" y="46">Folder stack</text>')
card('dock', 'Dock', 'Widgets, groups, stacks, activity icons, magnification',
     'A dock with a magnified icon, a group grid popover, a badge, an activity dot, and clock and battery widgets.', '\n'.join('  '+x for x in b))

# Top Notch
b = []
b.append('<rect class="bar" x="24" y="24" width="392" height="22" rx="0"/>')
b.append('<path class="notch" d="M84 24 h272 v160 a18 18 0 0 1 -18 18 h-236 a18 18 0 0 1 -18 -18z"/>')
b.append('<rect class="accent" x="98" y="30" width="14" height="14" rx="4"/>')
for i, h in enumerate((6, 10, 4, 8)):
    b.append(f'<rect class="light" x="{118+i*5}" y="{43-h}" width="3" height="{h}" rx="1.5"/>')
b.append('<circle class="accent" cx="330" cy="37" r="4"/><circle class="light" cx="342" cy="37" r="4" fill-opacity=".5"/>')
tabs = ['Widgets', 'Agents', 'Files', 'Clipboard']
x = 98
for i, t in enumerate(tabs):
    w = len(t)*6.2 + 14
    if i == 0:
        b.append(f'<rect class="light" x="{x}" y="56" width="{w:.0f}" height="20" rx="10" fill-opacity=".18"/>')
    b.append(f'<text class="tl" x="{x+7}" y="70"{" fill-opacity=\".55\"" if i else ""}>{t}</text>')
    x += w + 4
# music card
b.append('<rect class="light" x="124" y="86" width="192" height="104" rx="12" fill-opacity=".08"/>')
b.append('<rect class="accent" x="134" y="96" width="48" height="48" rx="8"/>')
b.append('<circle cx="158" cy="120" r="12" fill="#10283F" fill-opacity=".35"/><circle class="light" cx="158" cy="120" r="3"/>')
b.append('<text class="tl" x="192" y="112">Harbor Lights</text>')
b.append('<text class="tl" x="192" y="128" fill-opacity=".55">The Sailcloths</text>')
b.append('<rect class="light" x="134" y="156" width="172" height="4" rx="2" fill-opacity=".2"/><rect class="accent" x="134" y="156" width="96" height="4" rx="2"/>')
b.append('<path class="light" d="M196 170 l-9 6 l9 6z M214 168 v16 M220 168 v16" stroke="#F4EEDF" stroke-width="3" stroke-linecap="round"/>')
b.append('<path class="light" d="M236 170 l9 6 l-9 6z"/>')
b.append('<text class="tm" x="368" y="96">hover</text><text class="tm" x="368" y="110">to open</text>')
b.append('<path class="aline" d="M376 82 q0 -20 -14 -36" stroke-width="2" stroke-linecap="round"/>')
card('top-notch', 'Top Notch', 'A shelf around the notch: music, agents, files, clipboard, AirPods',
     'The notch opened into a shelf with tabs and a music card with album art, progress and controls.', '\n'.join('  '+x for x in b))

# Menu Bar Shelf
b = []
b.append('<rect class="faint" x="24" y="24" width="392" height="180" rx="12"/>')
b.append('<rect class="bar" x="24" y="24" width="392" height="30" rx="12"/>')
# visualizer bars behind
for i in range(40):
    h = 6 + 14*abs(math.sin(i*0.7)) * (0.5 + 0.5*abs(math.cos(i*0.23)))
    b.append(f'<rect class="accent" x="{34+i*9.5:.1f}" y="{54-h:.1f}" width="6" height="{h:.1f}" rx="2" fill-opacity=".22"/>')
b.append('<rect class="ink" x="36" y="33" width="12" height="12" rx="3"/>')
b.append('<text class="t" x="58" y="43">Finder   File   Edit</text>')
# hidden section dashed
b.append('<rect class="dash" x="222" y="29" width="84" height="20" rx="6"/>')
for i in range(3):
    b.append(icon(232 + i*24, 33, 12))
b.append('<rect class="accent" x="314" y="30" width="2" height="18" rx="1"/>')
for i in range(3):
    b.append(icon(326 + i*22, 33, 12, 'ink'))
b.append('<text class="tm" x="236" y="72">Hidden</text><text class="tm" x="330" y="72">Visible</text>')
# portside bar
b.append('<rect class="panel" x="176" y="96" width="150" height="40" rx="12"/>')
for i in range(5):
    b.append(icon(188 + i*26, 106, 20, 'ink' if i == 1 else 'soft'))
b.append('<text class="t" x="176" y="88">Portside Bar</text>')
b.append('<path class="panel" d="M216 136 v0"/>')
# a dropdown menu from item
b.append('<rect class="panel" x="200" y="142" width="120" height="54" rx="8"/>')
b.append('<rect class="tint" x="206" y="148" width="108" height="16" rx="4"/>')
b.append('<rect class="soft" x="212" y="153" width="64" height="6" rx="3"/><rect class="soft" x="212" y="173" width="80" height="6" rx="3"/><rect class="soft" x="212" y="185" width="52" height="6" rx="3"/>')
b.append('<text class="tm" x="40" y="120">Click the icon,</text><text class="tm" x="40" y="134">scroll, or hover</text><text class="tm" x="40" y="148">to reveal</text>')
card('menu-bar', 'Menu Bar Shelf', 'Hide and group items, open them in the Portside Bar, music visualizer',
     'A menu bar with a dashed hidden section, a divider, a music visualizer behind it, and the Portside Bar showing an app menu.', '\n'.join('  '+x for x in b))

# Command Center
b = []
b.append('<rect class="panel" x="40" y="22" width="360" height="190" rx="16"/>')
b.append('<rect class="faint" x="54" y="36" width="332" height="34" rx="10"/>')
b.append('<circle cx="72" cy="53" r="6" fill="none" stroke="#F06A42" stroke-width="2"/><path d="M76.5 57.5 l4 4" stroke="#F06A42" stroke-width="2" stroke-linecap="round"/>')
b.append('<text class="t" x="88" y="58">port 5173</text><rect class="accent" x="146" y="44" width="1.5" height="18"/>')
b.append('<text class="key" x="376" y="57" text-anchor="end">⌥Space</text>')
rows = [('localhost:5173', 'node · my-app', True, 'Open'), ('Stop Server', 'Asks first, SIGTERM only', False, ''), ('Safari', 'Application', False, ''), ('2 + 2 = 4', 'Calculator, copy result', False, '')]
y = 80
for title, sub, sel, act in rows:
    if sel:
        b.append(f'<rect class="tint" x="54" y="{y}" width="332" height="30" rx="8"/>')
    b.append(icon(62, y+6, 18, 'ink' if sel else 'soft'))
    b.append(f'<text class="t" x="90" y="{y+14}">{title}</text><text class="tm" x="90" y="{y+26}">{sub}</text>')
    if act:
        b.append(f'<text class="key" x="376" y="{y+19}" text-anchor="end">↩ {act}</text>')
    y += 32
card('command-center', 'Command Center', 'Apps, commands, files, snippets, servers, math, emoji',
     'A search panel with the query port 5173 showing a local server, a stop action, an app and a calculator result.', '\n'.join('  '+x for x in b))

# App Switcher
b = []
b.append('<rect class="panel" x="40" y="28" width="360" height="96" rx="20"/>')
for i in range(5):
    x = 56 + i*68
    if i == 1:
        b.append(f'<rect class="tint" x="{x-6}" y="38" width="64" height="64" rx="14"/>')
    b.append(icon(x, 44, 52, 'ink' if i == 1 else 'soft'))
b.append('<text class="t" x="138" y="116" text-anchor="middle">Notes</text>')
b.append('<text class="key" x="386" y="116" text-anchor="end">⌥Tab</text>')
b.append('<rect class="panel" x="96" y="132" width="210" height="80" rx="12"/>')
wins = ['Groceries', 'Trip ideas', 'Meeting notes']
for i, w in enumerate(wins):
    yy = 140 + i*24
    if i == 0:
        b.append(f'<rect class="tint" x="102" y="{yy}" width="198" height="20" rx="5"/>')
    b.append(f'<rect class="soft" x="110" y="{yy+5}" width="14" height="10" rx="2"/><text class="t" x="132" y="{yy+14}">{w}</text>')
b.append('<text class="key" x="316" y="160">↓ windows</text><text class="key" x="316" y="178">/ search</text>')
card('app-switcher', 'App Switcher', 'Apps or windows in recent order; ⌘Tab stays native',
     'A switcher row of app icons with Notes selected and a list of its windows below.', '\n'.join('  '+x for x in b))

# Widgets
b = []
def tile(x, y, w, h):
    return f'<rect class="panel" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>'
b.append(tile(24, 24, 120, 84))
b.append('<text class="big" x="38" y="66">9:41</text><text class="tm" x="38" y="86">Thursday 26</text>')
b.append(tile(152, 24, 120, 84))
b.append('<circle class="accent" cx="180" cy="54" r="12"/><text class="big" x="200" y="62">18°</text><text class="tm" x="166" y="92">Lisbon, sunny</text>')
b.append(tile(280, 24, 136, 84))
b.append('<text class="t" x="294" y="44">CPU</text>')
pts = ' '.join(f'{294+i*9},{96-18*abs(math.sin(i*0.6))-6*((i*7)%3)}' for i in range(14))
b.append(f'<polyline class="aline" points="{pts}" stroke-width="2" stroke-linejoin="round"/>')
b.append(tile(24, 116, 196, 96))
b.append('<text class="t" x="38" y="138">AI Usage</text>')
for i, (n, v) in enumerate((('Claude', .62), ('Codex', .35), ('Copilot', .8))):
    yy = 152 + i*20
    b.append(f'<text class="tm" x="38" y="{yy+8}">{n}</text><rect class="soft" x="96" y="{yy}" width="108" height="8" rx="4"/><rect class="accent" x="96" y="{yy}" width="{108*v:.0f}" height="8" rx="4"/>')
b.append(tile(228, 116, 188, 96))
b.append('<text class="t" x="242" y="138">Agents</text>')
for i, (n, s) in enumerate((('Claude Code', 'working'), ('Codex', 'done'))):
    yy = 156 + i*24
    b.append(f'<circle class="{"accent" if i == 0 else "green"}" cx="248" cy="{yy}" r="5"/><text class="t" x="260" y="{yy+4}">{n}</text><text class="tm" x="402" y="{yy+4}" text-anchor="end">{s}</text>')
card('widgets', 'Widgets', 'Clock, Weather, system stats, Now Playing, Agents, AI Usage',
     'Widget tiles: a clock, weather, a CPU graph, AI usage meters for Claude, Codex and Copilot, and agent status.', '\n'.join('  '+x for x in b))

def strip(x, y, w, h=34):
    return f'<rect class="notch" x="{x}" y="{y}" width="{w}" height="{h}" rx="{h/2:.0f}"/>'

def ship(x, y, cls='light'):
    # Portside's sailboat: two sails over a hull
    return (f'<path class="{cls}" d="M{x+9} {y} l0 12 l-7 0z"/>'
            f'<path class="{cls}" d="M{x+11} {y+2} q6 5 6 10 l-6 0z" fill-opacity=".7"/>'
            f'<path class="accent" d="M{x} {y+14} h20 l-4 5 h-12z"/>')

# Music visualizer
def mbar(y, label):
    return [f'<rect class="bar" x="24" y="{y}" width="392" height="36" rx="10"/>',
            f'<rect class="ink" x="36" y="{y+12}" width="12" height="12" rx="3"/>',
            f'<text class="tm" x="56" y="{y+22}">{label}</text>',
            f'<rect class="ink" x="364" y="{y+12}" width="12" height="12" rx="3"/><rect class="ink" x="384" y="{y+12}" width="12" height="12" rx="3"/>']
b = []
defs = ('<defs><radialGradient id="glow" cx="50%" cy="50%" r="50%">'
        '<stop offset="0" stop-color="#F06A42" stop-opacity=".85"/><stop offset=".6" stop-color="#F06A42" stop-opacity=".25"/>'
        '<stop offset="1" stop-color="#F06A42" stop-opacity="0"/></radialGradient>'
        '<linearGradient id="wave" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3BB3C3" stop-opacity=".55"/>'
        '<stop offset="1" stop-color="#3BB3C3" stop-opacity="0"/></linearGradient></defs>')
b += mbar(26, 'Glow')
b.append('<ellipse cx="220" cy="44" rx="150" ry="22" fill="url(#glow)"/>')
b += mbar(72, 'Bars')
for i in range(-16, 17):
    h = 4 + 24 * math.exp(-(i / 9) ** 2) * (0.55 + 0.45 * abs(math.sin(i * 1.3)))
    b.append(f'<rect x="{217+i*8.5:.1f}" y="{104-h:.1f}" width="5.5" height="{h:.1f}" rx="2" fill="#E0457B" fill-opacity=".8"/>')
b += mbar(118, 'Wave')
pts = []
for i in range(0, 241, 4):
    t = i / 240
    taper = math.sin(math.pi * t)
    yv = 138 - taper * (7 * math.sin(t * 6.3) + 4 * math.sin(t * 15 + 1) + 2 * math.sin(t * 31))
    pts.append(f'{100+i},{yv:.1f}')
b.append(f'<path d="M100 150 L{" L".join(pts)} L340 150z" fill="url(#wave)"/>')
b.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="#3BB3C3" stroke-width="2" stroke-linejoin="round"/>')
b.append('<rect class="accent" x="24" y="170" width="34" height="34" rx="7"/><circle cx="41" cy="187" r="9" fill="#10283F" fill-opacity=".35"/>')
b.append('<text class="t" x="68" y="184">Color from the album</text><text class="tm" x="68" y="199">or Accent, or Rainbow</text>')
for i, (n, w) in enumerate((('Calm', 40), ('Lively', 46))):
    pass
b.append('<text class="tm" x="250" y="184">Reactiveness</text>')
b.append('<rect class="soft" x="250" y="192" width="166" height="4" rx="2"/><rect class="accent" x="250" y="192" width="100" height="4" rx="2"/><circle class="accent" cx="350" cy="194" r="6"/>')
card('visualizer', 'Music visualizer', 'The menu bar moves with the song: Glow, Bars or Wave',
     'Three menu bars: one with a glow, one with a mirrored spectrum, one with a wave, plus album color and a reactiveness slider.',
     '\n'.join('  ' + x for x in b), defs=defs)

# Agents
b = []
b.append(strip(28, 34, 170, 32))
b.append(ship(44, 39))
b.append('<rect class="notch" x="80" y="34" width="70" height="32"/>')
b.append('<circle class="accent" cx="176" cy="50" r="9"/><text class="tl" x="176" y="54" text-anchor="middle">2</text>')
b.append('<text class="tm" x="28" y="86">Top Notch</text>')
b.append('<rect class="panel" x="224" y="28" width="64" height="44" rx="10"/>')
b.append('<circle cx="256" cy="50" r="12" fill="none" stroke="#F06A42" stroke-opacity=".2" stroke-width="3"/>')
b.append('<path d="M256 38 a12 12 0 0 1 12 12" fill="none" stroke="#F06A42" stroke-width="3" stroke-linecap="round"/>')
b.append('<circle class="accent" cx="282" cy="32" r="7"/><text class="tl" x="282" y="35.5" text-anchor="middle" font-size="9">2</text>')
b.append('<text class="tm" x="224" y="86">Dock widget</text>')
b.append(icon(330, 28, 44, 'soft'))
for i in range(3):
    b.append(f'<circle class="accent" cx="{338+i*7}" cy="36" r="2.6" fill-opacity="{1-i*0.3:.1f}"/>')
b.append('<text class="tm" x="330" y="86">Working dots</text>')
b.append('<rect class="panel" x="24" y="98" width="392" height="112" rx="12"/>')
rows = [('Claude Code', 'portside', 'working', 'accent'), ('Codex', 'api-server', 'done', 'green'),
        ('ChatGPT', 'Trip plan', 'working', 'accent'), ('OpenCode', 'site', 'needs you', 'accent')]
for i, (n, proj, st, c) in enumerate(rows):
    yy = 116 + i * 25
    b.append(f'<circle class="{c}" cx="42" cy="{yy}" r="5"/><text class="t" x="56" y="{yy+4}">{n}</text>')
    b.append(f'<text class="tm" x="170" y="{yy+4}">{proj}</text><text class="tm" x="400" y="{yy+4}" text-anchor="end">{st}</text>')
card('agents', 'Agent status', 'Every coding agent at a glance; click one to jump back to it',
     'Coding agent progress shown three ways: a sailboat and count in the notch, a spinning widget ring, and dots on an app icon, over a list of sessions.',
     '\n'.join('  ' + x for x in b))

# Notch indicator and alerts
b = []
def nrow(y):
    return [strip(70, y, 300, 36), f'<rect class="notch" x="170" y="{y}" width="100" height="36"/>']
b += nrow(26)
b.append('<path class="light" d="M88 39 h5 l6 -5 v16 l-6 -5 h-5z"/><path d="M103 38 q4 6 0 12 M107 35 q7 9 0 18" stroke="#F4EEDF" stroke-width="1.8" fill="none" stroke-linecap="round"/>')
b.append('<rect class="light" x="280" y="41" width="56" height="6" rx="3" fill-opacity=".25"/><rect class="light" x="280" y="41" width="35" height="6" rx="3"/>')
b.append('<text class="tl" x="356" y="48" text-anchor="end">62</text>')
b += nrow(76)
b.append('<rect class="light" x="86" y="86" width="16" height="16" rx="3" fill-opacity=".9"/><rect x="86" y="86" width="16" height="5" rx="2" fill="#FF453A"/>')
b.append('<text class="tl" x="108" y="99">Standup</text><text class="key" x="356" y="98" text-anchor="end">in 4:12</text>')
b += nrow(126)
b.append('<rect class="light" x="88" y="135" width="6" height="16" rx="3"/><rect class="light" x="98" y="135" width="6" height="16" rx="3"/>')
b.append('<text class="tl" x="112" y="148">AirPods</text>')
b.append('<rect class="green" x="290" y="139" width="40" height="8" rx="3"/><text class="tl" x="356" y="148" text-anchor="end">82</text>')
b.append('<text class="tm" x="24" y="190">Also: charger and low battery, rain soon, an agent done,</text>')
b.append('<text class="tm" x="24" y="205">the new song, files dropped on the notch</text>')
card('notch-alerts', 'Notch indicators', 'Volume and brightness, meetings, AirPods and short alerts',
     'Three notch strips: a volume level of 62, a meeting starting in 4 minutes, and AirPods at 82 percent.',
     '\n'.join('  ' + x for x in b))

# Settings
b = []
b.append('<rect class="panel" x="24" y="22" width="392" height="190" rx="12"/>')
b.append('<rect class="faint" x="24" y="22" width="120" height="190" rx="12"/>')
b.append('<rect class="panel" x="32" y="32" width="104" height="20" rx="6"/><text class="tm" x="40" y="46">Search</text><text class="key" x="130" y="46" text-anchor="end">⌘F</text>')
side = ['Dock', 'Appearance', 'Widgets', None, 'Command Center', 'Menu Bar', 'Top Notch', None, 'General']
yy = 70
for n in side:
    if n is None:
        yy += 6
        continue
    if n == 'Dock':
        b.append(f'<rect class="tint" x="30" y="{yy-11}" width="108" height="16" rx="5"/>')
    b.append(f'<text class="tm" x="40" y="{yy}">{n}</text>')
    yy += 17
b.append('<text class="t" x="158" y="44">Dock</text><text class="tm" x="402" y="44" text-anchor="end">Simulation</text>')
b.append('<rect class="faint" x="158" y="54" width="244" height="94" rx="10"/>')
b.append('<rect class="panel" x="214" y="118" width="132" height="22" rx="8"/>')
for i in range(5):
    b.append(icon(222 + i * 24, 122, 14, 'ink' if i == 0 else 'soft'))
b.append('<path class="aline" d="M380 140 v-22 m-6 6 l6 -6 l6 6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')
b.append('<rect class="panel" x="166" y="62" width="86" height="20" rx="10"/><text class="tm" x="178" y="76">Touch the edge</text>')
for i, (n, on) in enumerate((('Auto-hide', True), ('Keep windows clear', True))):
    y2 = 166 + i * 24
    b.append(f'<text class="t" x="158" y="{y2+4}">{n}</text>')
    b.append(f'<rect class="{"accent" if on else "soft"}" x="372" y="{y2-7}" width="30" height="16" rx="8"/><circle class="light" cx="394" cy="{y2+1}" r="6"/>')
card('settings', 'Settings', 'Live previews, search, permissions, restricted mode for work Macs',
     'The Settings window with a searchable sidebar, a Dock simulation preview and switches.',
     '\n'.join('  ' + x for x in b))

# Privacy: what stays on the Mac and the only hosts it talks to
b = []
b.append('<rect class="panel" x="24" y="24" width="456" height="210" rx="16"/>')
b.append('<text class="t" x="44" y="52">Stays on your Mac</text>')
local = ['Settings (dock.json)', 'Clipboard history, encrypted', 'Audio levels, never saved',
         'Window previews, in memory', 'On-device AI, no cloud', 'Agent hook files']
for i, n in enumerate(local):
    x = 44 + (i % 2) * 214
    y = 66 + (i // 2) * 44
    b.append(f'<rect class="faint" x="{x}" y="{y}" width="202" height="34" rx="9"/><circle class="green" cx="{x+16}" cy="{y+17}" r="4"/><text class="t" x="{x+28}" y="{y+21}">{n}</text>')
hosts = [('GitHub', 'update checks'), ('Open-Meteo', 'Weather widget'), ('Anthropic, GitHub', 'AI Usage, after you agree'), ('Spotify', 'cover art')]
for i, (h, why) in enumerate(hosts):
    y = 28 + i * 52
    b.append(f'<path class="dash" d="M480 129 C 540 129, 540 {y+20}, 596 {y+20}" stroke-width="1.5"/>')
    b.append(f'<rect class="panel" x="596" y="{y}" width="260" height="40" rx="10"/><text class="t" x="612" y="{y+17}">{h}</text><text class="tm" x="612" y="{y+32}">{why}</text>')
card('privacy', 'No telemetry, no account', 'Only these hosts, only when you use the feature that needs them',
     'Things that stay on the Mac on the left; dashed lines to the only four kinds of hosts Portside contacts on the right.',
     '\n'.join('  ' + x for x in b), W=880, H=320)
