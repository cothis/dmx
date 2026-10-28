#!/usr/bin/env python3
"""Render the self-contained verification report from formal/findings.json."""
from html import escape
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
data = json.loads((HERE / "findings.json").read_text())


def e(value):
    return escape(str(value))


def bullets(values):
    return "<ul>" + "".join(f"<li>{e(v)}</li>" for v in values) + "</ul>"


def evidence(path):
    return f'<a href="{e("../" + path.removeprefix("formal/"))}">{e(path.split("/evidence/")[-1])}</a>'


parts = []
for f in data["findings"]:
    prop = next(p for p in data["properties"] if p["name"] == f["property"])
    rows = "".join(
        f'<tr class="{"violation" if t.get("violation") else ""}"><td>{t["step"]}</td>'
        f'<td>{e(t["actor"])}<br><small>{e(t["code"])}</small></td>'
        f'<td>{e(t["action"])}<br><code>{e(json.dumps(t["changed"]))}</code></td></tr>'
        for t in f["trace"]
    )
    parts.append(f'''<section>
      <p class="eyebrow">{e(f['id'])} · {e(f['severity'])} severity · {e(f['status'])}</p>
      <h2>{e(f['title'])}</h2><p>{e(f['story'])}</p>
      <p><code>{e(prop['statement'])}</code> — {e(prop['meaning'])}</p>
      {f['diagram_html']}
      <h3>Counterexample</h3>
      <p>Baseline TLC trace: six states including initialization; Submit and Acquire are combined
      in row 1 below. The deterministic socket tests replay the critical Close → Reuse → I/O suffix.</p>
      <div class="scroll"><table><thead><tr><th>Step</th><th>Actor / code</th><th>Action / changed state</th></tr></thead>
      <tbody>{rows}</tbody></table></div>
      <h3>Real reproduction</h3><p><code>{e(f['reproduction']['test'])}</code></p>
      <p>{e(f['reproduction']['detail'])}</p>
      <p>Before fix: <strong>{e(f['reproduction']['result_before_fix'])}</strong>.
      After fix: <strong>{e(f['reproduction']['result_after_fix'])}</strong>.</p>
      <h3>Fix</h3><p>{e(f['fix']['summary'])}</p>
      <p>Core of the change (the complete source diff also routes both frame paths through this helper):</p>
      <pre>{e(f['fix']['diff'])}</pre>
      <p>Model recheck: {e(f['fix']['model_recheck'])}. Mutation: {e(f['fix']['mutation_check'])}.</p>
      <p class="evidence">Evidence: {' · '.join(evidence(p) for p in f['evidence'])}</p>
    </section>''')

property_rows = "".join(
    f'<tr><td><code>{e(p["name"])}</code><br>{e(p["meaning"])}</td>'
    f'<td>{e(p["kind"])}</td><td>{e(p["result"])}<br>{evidence(p["evidence"])}</td></tr>'
    for p in data["properties"]
)
validation_rows = "".join(
    f'<tr><td>{e(v["name"])}</td><td>{e(v["result"])}</td><td>{evidence(v["evidence"])}</td></tr>'
    for v in data["validation"]
)
scope = "".join(f'<h3>{e(label)}</h3>{bullets(data["scope"][key])}' for label, key in [
    ("Modeled", "modeled"), ("Abstracted", "abstracted"),
    ("Out of scope", "out_of_scope"), ("Assumptions", "assumptions")
])
trust = data["trust_base"]["tla"]
trust_paths = ["model-after/tlc.log", "mutation/tlc.log", "sanity-completion/tlc.log",
               "sanity-reuse/tlc.log", "sany.log", "correspondence.log",
               "skill-correspondence.log", "toolchain.log", "baseline-hashes.txt"]
trust_links = " · ".join(evidence("formal/frame-connection-lifetime/evidence/" + p) for p in trust_paths)
embedded = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
html = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FrameConnection verification · dmx</title><style>
:root{{--fv-bg:#faf9f5;--fv-bad:#a62e25;--fv-muted:#667169;color:#202c27;background:var(--fv-bg);font-family:system-ui,sans-serif;line-height:1.6}}
*{{box-sizing:border-box}}body{{margin:0}}main{{max-width:1040px;margin:auto;padding:56px 28px 80px}}
header{{border-top:5px solid #205b45;padding-top:18px}}h1{{font-family:Georgia,serif;font-size:clamp(2rem,5vw,3.5rem);line-height:1.1;letter-spacing:-.035em;margin:12px 0 20px}}h2{{line-height:1.25;letter-spacing:-.02em;font-size:1.7rem}}h3{{font-size:1.05rem;margin-top:30px}}
.eyebrow{{text-transform:uppercase;letter-spacing:.12em;font-size:.75rem;font-weight:700;color:#425f51}}.verdict{{font-size:1.2rem;background:#e8eee7;padding:20px 24px;border-left:4px solid #205b45}}.meta,small,.evidence{{color:var(--fv-muted);font-size:.83rem}}section{{padding:28px 0;border-bottom:1px solid #d6dcd4}}a{{color:#14553c;text-underline-offset:3px}}a:hover{{color:var(--fv-bad)}}p,li{{max-width:86ch}}li{{margin:8px 0}}
pre{{background:#edf0e9;padding:20px;overflow-x:auto;font-size:.82rem;line-height:1.6;border-radius:4px}}code{{font-family:ui-monospace,monospace;font-size:.85em;overflow-wrap:anywhere}}table{{border-collapse:collapse;width:100%;text-align:left;font-size:.9rem}}th,td{{padding:14px 12px;border-bottom:1px solid #d6dcd4;vertical-align:top}}th{{font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:#425f51}}.violation{{background:#fae9e4}}.scroll{{overflow-x:auto}}figure{{margin:30px 0;overflow-x:auto}}figure svg{{width:100%;min-width:680px;height:auto}}figcaption{{font-size:.8rem;color:var(--fv-muted);margin:10px 0}}
@media(max-width:640px){{main{{padding:30px 18px}}td,th{{padding:10px 8px}}.verdict{{padding:16px}}}}
@media(prefers-color-scheme:dark){{:root{{--fv-bg:#17211c;--fv-bad:#f29a87;--fv-muted:#a7b9ac;color:#e1e9df}}.eyebrow,th{{color:#b7d5be}}.verdict,pre{{background:#243a2d}}section,th,td{{border-color:#3a4a3e}}a{{color:#a4dab6}}.violation{{background:#462b29}}}}
</style></head><body><main>
<header><p class="eyebrow">dmx · W1 formal bug hunt · 2026-10-29</p>
<h1>FrameConnection<br>descriptor lifetime</h1>
<p class="verdict">{e(data['summary'])}</p>
<p class="meta">Baseline {e(data['repo_commit'])} · {e(data['generated_at'])} · source fix, no signed release published</p></header>
{''.join(parts)}
<section><h2>What was verified</h2><p>{e(data['properties'][0]['bounds'])}.</p>
<p>{trust['states_generated']} states generated; {trust['distinct_states']} distinct states; complete graph depth {trust['depth']}.</p>
<div class="scroll"><table><thead><tr><th>Property</th><th>Kind</th><th>Result / evidence</th></tr></thead><tbody>{property_rows}</tbody></table></div>
<h3>Code and real-VM validation</h3><div class="scroll"><table><thead><tr><th>Check</th><th>Result</th><th>Evidence</th></tr></thead><tbody>{validation_rows}</tbody></table></div>
<p>Memory values are single before/after measurements, not a statistical comparison. They measure ri_phys_footprint of the VM process. The duplicate descriptors add ownership, not guest RAM.</p></section>
<section><h2>Scope and assumptions</h2>{scope}</section>
<section><h2>Trust base and non-vacuity</h2><p>{e(trust['tool_version'])}.</p>{bullets(trust['sanity_checks'])}
{bullets(data['trust_base']['notes'])}<p class="evidence">Evidence: {trust_links}</p></section>
<section><h2>Re-run</h2><p>Run from the repository root; Java and a local TLA+ tools jar are required. See formal/README.md.</p>
<pre>{e(chr(10).join(data['rerun']))}</pre></section>
<section><h2>Next steps</h2>{bullets(data['next_steps'])}</section>
<p class="meta">Self-contained local report. No Artifact publishing tool was available in this session.</p>
</main><script type="application/json" id="verification-data">{embedded}</script></body></html>'''
destination = HERE / "reports" / f"{data['concern']}.html"
destination.parent.mkdir(exist_ok=True)
destination.write_text(html)
print(destination)
