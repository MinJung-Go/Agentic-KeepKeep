"""Build the standalone auxiliary preview: python3 docs/09-ui-refinement/build-preview.py."""
from pathlib import Path
import base64
import subprocess

root = Path(__file__).resolve().parent
html = (root / "design.template.html").read_text()
script = (root / "design.js").read_text()
css = (root / "design.css").read_text()
logo_path = "../../AgenticKeepKeep/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
logo = "data:image/png;base64," + base64.b64encode((root / logo_path).read_bytes()).decode()
script = script.replace(logo_path, logo)
# Render the initial six screens at build time; JS only adds interactivity.
source = script.split("function render()", 1)[0]
source += """
process.stdout.write(['dark','light'].flatMap((theme,ti)=>specs.map(([type,title,desc,fn],i)=>{
 const id=`${type}-${theme}`;
 return `<article class="scene" data-theme="${theme}" id="${id}"><header class="scene-label"><span class="no">${String(ti*specs.length+i+1).padStart(2,'0')} / ${theme==='dark'?'DARK':'LIGHT'}</span><h2>${title}</h2><p>${desc}</p></header><div class="phone ${theme}" data-kind="${type}">${fn(id)}</div></article>`;
})).join(''));
"""
markup = subprocess.run(["node", "-"], input=source, text=True, capture_output=True, check=True).stdout
html = html.replace(logo_path, logo)
html = html.replace('<link rel="stylesheet" href="design.css">', '<style>\n' + css + '\n</style>')
html = html.replace('<main id="gallery" class="gallery" aria-label="全部手机界面设计"></main>', '<main id="gallery" class="gallery" aria-label="全部手机界面设计">' + markup + '</main>')
html = html.replace('<script src="design.js"></script>', '<script>\n' + script.replace('</script', '<\\/script') + '\n</script>')
(root / "design.html").write_text(html)
print("Built standalone design.html with 32 static screens.")
