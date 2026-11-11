import { describe, expect, it } from "vitest";
import { metricColor, metricColorCSS } from "../src/metric-style";
import palette from "../src/metric-colors.json";

describe("shared native/web metric colours",()=>{
  it("keeps aliases and component keys stable regardless of selection order",()=>{
    for(const [key,spec] of Object.entries(palette)) for(const alias of [key,...spec.aliases]) expect(metricColor(alias)).toBe(metricColor(key));
    expect(metricColor("sleepMinutes")).toBe(metricColor("Sleep"));
    expect(metricColor("Training demand")).toBe(metricColor("acuteLoad"));
    expect(metricColor("fitness")).not.toBe(metricColor("recovery"));
    const css=metricColorCSS();expect(css).toContain("prefers-color-scheme:dark");
    for(const spec of Object.values(palette)) {expect(css).toContain(spec.light);expect(css).toContain(spec.dark);}
  });
});
