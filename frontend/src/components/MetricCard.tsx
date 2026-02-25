'use client';

import { ReactNode } from 'react';
import { clsx } from 'clsx';

interface Props {
  title: string;
  value: string | number;
  subtitle?: string;
  icon?: ReactNode;
  trend?: 'up' | 'down' | 'neutral';
  highlight?: boolean;
  className?: string;
}

export function MetricCard({
  title,
  value,
  subtitle,
  icon,
  trend,
  highlight,
  className,
}: Props) {
  return (
    <div
      className={clsx(
        'rounded-xl border p-4 backdrop-blur-sm transition-all duration-200 hover:scale-[1.02]',
        highlight
          ? 'border-green-500/40 bg-green-500/5 shadow-lg shadow-green-500/10'
          : 'border-white/10 bg-white/5',
        className
      )}
    >
      <div className="flex items-start justify-between">
        <div className="flex-1 min-w-0">
          <p className="text-xs text-gray-400 uppercase tracking-wider truncate">{title}</p>
          <p className={clsx(
            'text-2xl font-bold mt-1 truncate',
            highlight ? 'text-green-400' : 'text-white'
          )}>
            {value}
          </p>
          {subtitle && (
            <p className="text-xs text-gray-500 mt-0.5 truncate">{subtitle}</p>
          )}
        </div>
        {icon && (
          <div className={clsx(
            'ml-3 p-2 rounded-lg flex-shrink-0',
            highlight ? 'bg-green-500/20 text-green-400' : 'bg-white/10 text-gray-400'
          )}>
            {icon}
          </div>
        )}
      </div>
      {trend && (
        <div className={clsx(
          'mt-2 text-xs flex items-center gap-1',
          trend === 'up' ? 'text-red-400' : trend === 'down' ? 'text-green-400' : 'text-gray-400'
        )}>
          <span>{trend === 'up' ? '↑' : trend === 'down' ? '↓' : '→'}</span>
          <span>{trend === 'up' ? 'Increasing' : trend === 'down' ? 'Decreasing' : 'Stable'}</span>
        </div>
      )}
    </div>
  );
}
