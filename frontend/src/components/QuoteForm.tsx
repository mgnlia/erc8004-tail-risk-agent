'use client';

import { useState } from 'react';
import { Shield, Loader2, CheckCircle, XCircle } from 'lucide-react';
import { api, PolicyQuote } from '@/lib/api';
import { clsx } from 'clsx';

interface FormState {
  requester: string;
  coverage_asset: string;
  coverage_amount_eth: string;
  duration_days: string;
  trigger_threshold: string;
}

export function QuoteForm() {
  const [form, setForm] = useState<FormState>({
    requester: '0x742d35Cc6634C0532925a3b844Bc454e4438f44e',
    coverage_asset: 'ETH',
    coverage_amount_eth: '1.0',
    duration_days: '30',
    trigger_threshold: '20',
  });
  const [loading, setLoading] = useState(false);
  const [quote, setQuote] = useState<PolicyQuote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [issuing, setIssuing] = useState(false);
  const [issued, setIssued] = useState<boolean>(false);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setForm(prev => ({ ...prev, [e.target.name]: e.target.value }));
    setQuote(null);
    setError(null);
    setIssued(false);
  };

  const handleQuote = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    setQuote(null);
    setIssued(false);

    try {
      const result = await api.requestQuote({
        requester: form.requester,
        coverage_asset: form.coverage_asset,
        coverage_amount_eth: parseFloat(form.coverage_amount_eth),
        duration_days: parseInt(form.duration_days),
        trigger_threshold: parseFloat(form.trigger_threshold) / 100,
      });
      setQuote(result);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to get quote');
    } finally {
      setLoading(false);
    }
  };

  const handleIssue = async () => {
    if (!quote?.approved) return;
    setIssuing(true);
    try {
      await api.issuePolicy({
        requester: form.requester,
        coverage_asset: form.coverage_asset,
        coverage_amount_eth: parseFloat(form.coverage_amount_eth),
        duration_days: parseInt(form.duration_days),
        trigger_threshold: parseFloat(form.trigger_threshold) / 100,
      });
      setIssued(true);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to issue policy');
    } finally {
      setIssuing(false);
    }
  };

  return (
    <div className="rounded-xl border border-white/10 bg-white/5 backdrop-blur-sm overflow-hidden">
      <div className="border-b border-white/10 px-6 py-4 flex items-center gap-3">
        <Shield className="w-5 h-5 text-green-400" />
        <h2 className="text-lg font-semibold text-white">Request Insurance Quote</h2>
      </div>

      <form onSubmit={handleQuote} className="p-6 space-y-4">
        {/* Requester */}
        <div>
          <label className="block text-xs text-gray-400 mb-1.5 uppercase tracking-wider">
            Wallet Address
          </label>
          <input
            name="requester"
            value={form.requester}
            onChange={handleChange}
            placeholder="0x..."
            className="w-full bg-white/5 border border-white/10 rounded-lg px-3 py-2.5 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-green-500/50 focus:ring-1 focus:ring-green-500/20 font-mono"
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          {/* Asset */}
          <div>
            <label className="block text-xs text-gray-400 mb-1.5 uppercase tracking-wider">
              Asset
            </label>
            <select
              name="coverage_asset"
              value={form.coverage_asset}
              onChange={handleChange}
              className="w-full bg-gray-900 border border-white/10 rounded-lg px-3 py-2.5 text-sm text-white focus:outline-none focus:border-green-500/50"
            >
              {['ETH', 'BTC', 'SOL', 'AVAX', 'MATIC', 'LINK'].map(a => (
                <option key={a} value={a}>{a}</option>
              ))}
            </select>
          </div>

          {/* Coverage */}
          <div>
            <label className="block text-xs text-gray-400 mb-1.5 uppercase tracking-wider">
              Coverage (ETH)
            </label>
            <input
              name="coverage_amount_eth"
              type="number"
              step="0.1"
              min="0.1"
              max="10"
              value={form.coverage_amount_eth}
              onChange={handleChange}
              className="w-full bg-white/5 border border-white/10 rounded-lg px-3 py-2.5 text-sm text-white focus:outline-none focus:border-green-500/50"
            />
          </div>

          {/* Duration */}
          <div>
            <label className="block text-xs text-gray-400 mb-1.5 uppercase tracking-wider">
              Duration (Days)
            </label>
            <input
              name="duration_days"
              type="number"
              min="1"
              max="365"
              value={form.duration_days}
              onChange={handleChange}
              className="w-full bg-white/5 border border-white/10 rounded-lg px-3 py-2.5 text-sm text-white focus:outline-none focus:border-green-500/50"
            />
          </div>

          {/* Trigger */}
          <div>
            <label className="block text-xs text-gray-400 mb-1.5 uppercase tracking-wider">
              Trigger Drop (%)
            </label>
            <input
              name="trigger_threshold"
              type="number"
              min="5"
              max="80"
              step="5"
              value={form.trigger_threshold}
              onChange={handleChange}
              className="w-full bg-white/5 border border-white/10 rounded-lg px-3 py-2.5 text-sm text-white focus:outline-none focus:border-green-500/50"
            />
          </div>
        </div>

        <button
          type="submit"
          disabled={loading}
          className="w-full bg-green-500 hover:bg-green-400 disabled:bg-green-800 text-black font-semibold py-3 rounded-lg transition-colors flex items-center justify-center gap-2"
        >
          {loading ? (
            <>
              <Loader2 className="w-4 h-4 animate-spin" />
              Assessing Risk...
            </>
          ) : (
            <>
              <Shield className="w-4 h-4" />
              Get Quote
            </>
          )}
        </button>
      </form>

      {/* Error */}
      {error && (
        <div className="mx-6 mb-4 p-3 rounded-lg bg-red-500/10 border border-red-500/30 flex items-start gap-2">
          <XCircle className="w-4 h-4 text-red-400 mt-0.5 flex-shrink-0" />
          <p className="text-sm text-red-400">{error}</p>
        </div>
      )}

      {/* Quote Result */}
      {quote && (
        <div className={clsx(
          'mx-6 mb-6 p-4 rounded-xl border',
          quote.approved
            ? 'border-green-500/30 bg-green-500/5'
            : 'border-red-500/30 bg-red-500/5'
        )}>
          <div className="flex items-center gap-2 mb-3">
            {quote.approved ? (
              <CheckCircle className="w-5 h-5 text-green-400" />
            ) : (
              <XCircle className="w-5 h-5 text-red-400" />
            )}
            <span className={clsx(
              'font-semibold',
              quote.approved ? 'text-green-400' : 'text-red-400'
            )}>
              {quote.approved ? 'Quote Approved' : 'Quote Declined'}
            </span>
          </div>

          {quote.approved ? (
            <div className="space-y-2">
              <div className="grid grid-cols-2 gap-3">
                <div className="bg-white/5 rounded-lg p-3">
                  <div className="text-xs text-gray-400">Premium</div>
                  <div className="text-lg font-bold text-green-400">
                    {quote.premium_eth.toFixed(4)} ETH
                  </div>
                  <div className="text-xs text-gray-500">
                    {(quote.premium_rate * 100).toFixed(3)}% of coverage
                  </div>
                </div>
                <div className="bg-white/5 rounded-lg p-3">
                  <div className="text-xs text-gray-400">Risk Score</div>
                  <div className={clsx(
                    'text-lg font-bold',
                    quote.risk_score < 50 ? 'text-green-400' : quote.risk_score < 75 ? 'text-yellow-400' : 'text-red-400'
                  )}>
                    {quote.risk_score.toFixed(1)}/100
                  </div>
                  <div className="text-xs text-gray-500">Tail risk score</div>
                </div>
              </div>

              {issued ? (
                <div className="mt-3 p-3 rounded-lg bg-green-500/10 border border-green-500/30 text-center">
                  <CheckCircle className="w-5 h-5 text-green-400 mx-auto mb-1" />
                  <p className="text-sm text-green-400 font-semibold">Policy Issued!</p>
                  <p className="text-xs text-gray-400 mt-0.5">On-chain transaction submitted</p>
                </div>
              ) : (
                <button
                  onClick={handleIssue}
                  disabled={issuing}
                  className="w-full mt-2 bg-green-500/20 hover:bg-green-500/30 border border-green-500/40 text-green-400 font-semibold py-2.5 rounded-lg transition-colors flex items-center justify-center gap-2"
                >
                  {issuing ? (
                    <><Loader2 className="w-4 h-4 animate-spin" /> Issuing...</>
                  ) : (
                    <>Accept & Issue Policy</>
                  )}
                </button>
              )}
            </div>
          ) : (
            <p className="text-sm text-red-300">{quote.rejection_reason}</p>
          )}
        </div>
      )}
    </div>
  );
}
