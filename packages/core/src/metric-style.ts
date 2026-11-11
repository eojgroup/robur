import palette from "./metric-colors.json" with { type: "json" };
const normalize=(key:string)=>key.toLowerCase().replace(/[^a-z0-9]/g,"");
const keys=new Map(Object.entries(palette).flatMap(([key,value])=>[key,...value.aliases].map(alias=>[normalize(alias),key])));
export const metricColor=(key:string)=>`var(--metric-${keys.get(normalize(key))??"recovery"})`;
export const metricColorCSS=()=>`:root{${Object.entries(palette).map(([key,v])=>`--metric-${key}:${v.light}`).join(";")}}@media(prefers-color-scheme:dark){:root{${Object.entries(palette).map(([key,v])=>`--metric-${key}:${v.dark}`).join(";")}}`;
