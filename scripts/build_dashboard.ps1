$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dataPath = Join-Path $root 'data'
$reportPath = Join-Path $root 'reports'

$events = @(Import-Csv (Join-Path $dataPath 'usage_events.csv'))
$modelRates = @(Import-Csv (Join-Path $dataPath 'model_rates.csv'))
$departmentRates = @(Import-Csv (Join-Path $dataPath 'department_rates.csv'))
if ($events.Count -eq 0) {
    throw 'No usage events found. Run scripts\generate_data.ps1 first.'
}

$payload = [pscustomobject]@{
    events = $events
    modelRates = $modelRates
    departmentRates = $departmentRates
} | ConvertTo-Json -Depth 5 -Compress
$payload = $payload.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')

$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Token Analytics | AI Spend &amp; ROI</title>
<style>
:root{color-scheme:light;--ink:#172b4d;--muted:#60708a;--line:#dce4ef;--blue:#276ef1;--teal:#138a72;--red:#cf4b4b;--paper:#f4f7fb}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 "Segoe UI",Arial,sans-serif}
main{max-width:1180px;margin:0 auto;padding:32px 22px 56px}.eyebrow{color:var(--blue);font-size:12px;font-weight:700;letter-spacing:.13em;text-transform:uppercase}
h1{font-size:clamp(28px,4vw,42px);line-height:1.12;margin:8px 0 10px}h2{font-size:19px;margin:0 0 16px}
.lede{max-width:780px;color:var(--muted);margin:0 0 18px}.badge{display:inline-block;border:1px solid #e8c76b;background:#fff7d6;color:#604b0b;padding:5px 10px;border-radius:20px;font-size:12px;font-weight:700}
.grid{display:grid;gap:16px}.kpis{grid-template-columns:repeat(5,minmax(0,1fr));margin:22px 0}.card,.panel{background:#fff;border:1px solid var(--line);border-radius:12px;box-shadow:0 2px 8px #18385b0a}
.card{padding:16px}.label{color:var(--muted);font-size:12px;font-weight:600}.value{font-size:25px;font-weight:700;margin:5px 0}.note{font-size:11px;color:var(--muted)}
.panels{grid-template-columns:1.2fr 1fr}.panel{padding:20px;margin-bottom:16px}.wide{grid-column:1/-1}.chart{width:100%;height:auto;overflow:visible}.chart text{fill:var(--muted);font:11px "Segoe UI",Arial,sans-serif}.legend{display:flex;gap:18px;color:var(--muted);font-size:12px;margin:0 0 10px}.swatch{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:9px 7px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}.positive{color:var(--teal);font-weight:700}.negative{color:var(--red);font-weight:700}.small{color:var(--muted);font-size:12px}.callout{border-left:4px solid var(--blue);background:#f1f6ff;padding:13px 15px;margin-top:12px}
@media(max-width:850px){.kpis{grid-template-columns:repeat(2,1fr)}.panels{grid-template-columns:1fr}.wide{grid-column:auto}}@media(max-width:480px){main{padding:22px 14px}.kpis{grid-template-columns:1fr 1fr}.card{padding:12px}.value{font-size:20px}.panel{padding:14px;overflow-x:auto}}
</style>
</head>
<body><main>
<div class="eyebrow">AI unit economics | Portfolio demo</div>
<h1>Is AI spend paying off?</h1>
<p class="lede">A task-level view of token cost, estimated time reclaimed, and the review effort needed to get useful work. This is a decision-support prototype - not a claim about actual company returns.</p>
<span class="badge">SYNTHETIC SCENARIO DATA - NOT REAL COMPANY TELEMETRY</span>
<section class="grid kpis" id="kpis" aria-label="Key metrics"></section>
<section class="grid panels">
<article class="panel"><h2>Monthly spend vs. modeled capacity value</h2><div class="legend"><span><i class="swatch" style="background:#276ef1"></i>API spend</span><span><i class="swatch" style="background:#138a72"></i>Labor capacity value</span></div><div id="monthly"></div></article>
<article class="panel"><h2>Department ROI proxy</h2><p class="small">Modeled labor capacity value less API spend, divided by API spend.</p><div id="departments"></div></article>
<article class="panel wide"><h2>Workflow unit economics</h2><div id="workflows"></div></article>
<article class="panel wide"><h2>Model mix and task quality</h2><div id="models"></div></article>
</section>
<article class="panel"><h2>How to read this</h2>
<p class="small">Labor capacity value = (estimated minutes saved - review minutes) x assumed loaded hourly labor rate. ROI proxy is not cash ROI: time saved must be demonstrably redeployed or converted into avoided cost. Synthetic prices, wages, success rates, and time savings are scenario assumptions.</p>
<div class="callout"><strong>Next business step:</strong> use this segmentation to select a controlled pilot, instrument a credible baseline and quality measures, and validate realized outcomes with Finance before scaling.</div>
</article>
</main>
<script>
const data = __DATA__;
const modelRates = Object.fromEntries(data.modelRates.map(x => [x.model, {input:Number(x.input_usd_per_million), output:Number(x.output_usd_per_million)}]));
const laborRates = Object.fromEntries(data.departmentRates.map(x => [x.department, Number(x.loaded_labor_usd_per_hour)]));
const events = data.events.map(e => {
  const cost = Number(e.input_tokens)*modelRates[e.model].input/1e6 + Number(e.output_tokens)*modelRates[e.model].output/1e6;
  const value = (Number(e.minutes_saved)-Number(e.review_minutes))*laborRates[e.department]/60;
  return {...e, cost, value};
});
const sum = (rows, key) => rows.reduce((a,x)=>a+x[key],0);
const pct = n => `${n.toFixed(1)}%`;
const usd = n => `$${n.toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2})}`;
const roi = rows => (sum(rows,"value")-sum(rows,"cost"))/Math.max(sum(rows,"cost"),1e-12)*100;
const success = rows => rows.filter(x=>x.outcome==="success").length/Math.max(rows.length,1)*100;
const groups = (key) => Object.groupBy ? Object.groupBy(events,x=>x[key]) : events.reduce((a,x)=>((a[x[key]]??=[]).push(x),a),{});
const byMonth = Object.entries(events.reduce((acc,e)=>{const k=e.occurred_at.slice(0,7);(acc[k]??=[]).push(e);return acc},{})).sort((a,b)=>a[0].localeCompare(b[0]));
const byDept=groups("department"),byWorkflow=groups("workflow"),byModel=groups("model");
const kpiItems=[
  ["AI-assisted tasks",events.length.toLocaleString(),"Synthetic task records"],
  ["Estimated API spend",usd(sum(events,"cost")),"Simulated rate card"],
  ["Labor capacity value",usd(sum(events,"value")),"After modeled review effort"],
  ["ROI proxy",pct(roi(events)),"Not audited financial ROI"],
  ["Successful-task rate",pct(success(events)),"Success labels are simulated"]
];
document.getElementById("kpis").innerHTML=kpiItems.map(([l,v,n])=>`<div class="card"><div class="label">${l}</div><div class="value">${v}</div><div class="note">${n}</div></div>`).join("");
function monthlyChart(){
  const w=540,h=250,p=35,items=byMonth.map(([k,r])=>({k,c:sum(r,"cost"),v:sum(r,"value")}));
  const max=Math.max(...items.flatMap(x=>[x.c,x.v]),1),slot=(w-p*2)/items.length,bw=Math.min(24,slot*.3);
  let s=`<svg class="chart" viewBox="0 0 ${w} ${h}" role="img" aria-label="Monthly API spend compared with labor capacity value"><line x1="${p}" y1="${h-p}" x2="${w-p}" y2="${h-p}" stroke="#dce4ef"/>`;
  items.forEach((x,i)=>{const cx=p+slot*i+slot/2;for(const [j,val,color] of [[-1,x.c,"#276ef1"],[1,x.v,"#138a72"]]){const bh=(h-p*2)*val/max;s+=`<rect x="${cx+j*(bw+2)-bw/2}" y="${h-p-bh}" width="${bw}" height="${bh}" rx="3" fill="${color}"><title>${x.k}: ${usd(val)}</title></rect>`}s+=`<text x="${cx}" y="${h-11}" text-anchor="middle">${x.k.slice(5)}</text>`});
  s+=`<text x="7" y="18">USD</text></svg>`;return s;
}
document.getElementById("monthly").innerHTML=monthlyChart();
function deptTable(){
  return `<table><thead><tr><th>Department</th><th class="num">Tasks</th><th class="num">Spend</th><th class="num">ROI proxy</th></tr></thead><tbody>${Object.entries(byDept).map(([k,r])=>({k,r,p:roi(r)})).sort((a,b)=>b.p-a.p).map(x=>`<tr><td>${x.k}</td><td class="num">${x.r.length.toLocaleString()}</td><td class="num">${usd(sum(x.r,"cost"))}</td><td class="num ${x.p>=0?"positive":"negative"}">${pct(x.p)}</td></tr>`).join("")}</tbody></table>`;
}
document.getElementById("departments").innerHTML=deptTable();
function segmentTable(groups,key){
  return `<table><thead><tr><th>${key}</th><th class="num">Tasks</th><th class="num">Avg. cost / task</th><th class="num">Success</th><th class="num">ROI proxy</th></tr></thead><tbody>${Object.entries(groups).map(([k,r])=>({k,r,p:roi(r)})).sort((a,b)=>b.p-a.p).map(x=>`<tr><td>${x.k}</td><td class="num">${x.r.length.toLocaleString()}</td><td class="num">${usd(sum(x.r,"cost")/x.r.length)}</td><td class="num">${pct(success(x.r))}</td><td class="num ${x.p>=0?"positive":"negative"}">${pct(x.p)}</td></tr>`).join("")}</tbody></table>`;
}
document.getElementById("workflows").innerHTML=segmentTable(byWorkflow,"Workflow");
document.getElementById("models").innerHTML=segmentTable(byModel,"Model");
</script></body></html>
'@

$html = $html.Replace('__DATA__', $payload)
$output = Join-Path $reportPath 'dashboard.html'
[System.IO.File]::WriteAllText($output, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("Wrote dashboard to {0}" -f $output)
