'use client';

import { RadialBarChart, RadialBar, ResponsiveContainer } from 'recharts';

interface Props {
  score: number;
  label?: string;
  size?: number;
}

function getRiskColor(score: number): string {
  if (score < 25) return '#22c55e';   // green
  if (score < 50) return '#eab308';   // yellow
  if (score < 75) return '#f97316';   // orange
  return '#ef4444';                    // red
}

function getRiskLabel(score: number): string {
  if (score < 25) return 'LOW';
  if (score < 50) return 'MODERATE';
  if (score < 75) return 'HIGH';
  return 'EXTREME';
}

export function RiskGauge({ score, label, size = 160 }: Props) {
  const color = getRiskColor(score);
  const riskLabel = getRiskLabel(score);

  const data = [
    { name: 'risk', value: score, fill: color },
    { name: 'empty', value: 100 - score, fill: 'rgba(255,255,255,0.05)' },
  ];

  return (
    <div className="flex flex-col items-center gap-2">
      <div className="relative" style={{ width: size, height: size }}>
        <ResponsiveContainer width="100%" height="100%">
          <RadialBarChart
            cx="50%"
            cy="50%"
            innerRadius="60%"
            outerRadius="90%"
            data={data}
            startAngle={220}
            endAngle={-40}
            barSize={12}
          >
            <RadialBar dataKey="value" cornerRadius={6} />
          </RadialBarChart>
        </ResponsiveContainer>
        {/* Center text */}
        <div className="absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-2xl font-bold" style={{ color }}>
            {Math.round(score)}
          </span>
          <span className="text-xs text-gray-400">/100</span>
        </div>
      </div>
      <div className="text-center">
        <div className="text-xs font-semibold tracking-widest" style={{ color }}>
          {riskLabel}
        </div>
        {label && <div className="text-xs text-gray-500 mt-0.5">{label}</div>}
      </div>
    </div>
  );
}
