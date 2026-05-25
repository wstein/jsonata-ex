// Times jsonata-js (the reference implementation) on a shared workload.
//
// Reads {data, cases:[{name, expr}]} from the JSON file given as argv[2],
// evaluates each case repeatedly, and writes [{name, us}] (median microseconds
// per eval) to stdout. Driven by compare.exs, which feeds the *same* data and
// expressions to the Elixir engine so the two columns are comparable.

import jsonata from "jsonata";
import { readFileSync } from "node:fs";

const { data, cases } = JSON.parse(readFileSync(process.argv[2], "utf8"));

async function timeOne(expr) {
  const compiled = jsonata(expr);
  // warmup
  for (let i = 0; i < 50; i++) await compiled.evaluate(data);

  const samples = [];
  for (let s = 0; s < 11; s++) {
    const iterations = 200;
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < iterations; i++) await compiled.evaluate(data);
    const t1 = process.hrtime.bigint();
    samples.push(Number(t1 - t0) / 1000 / iterations); // µs per eval
  }
  samples.sort((a, b) => a - b);
  return samples[Math.floor(samples.length / 2)]; // median
}

const results = [];
for (const { name, expr } of cases) {
  results.push({ name, us: await timeOne(expr) });
}

process.stdout.write(JSON.stringify(results));
