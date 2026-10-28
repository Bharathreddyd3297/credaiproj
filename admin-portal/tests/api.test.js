import { afterEach, describe, expect, it, vi } from 'vitest';
import { aiApi, askAi, extractErrorMessage } from '../src/services/api';

afterEach(() => vi.restoreAllMocks());

describe('ai-service API', () => {
  it('askAi posts the question and the conversation to /api/ai/chat', async () => {
    const post = vi.spyOn(aiApi, 'post').mockResolvedValue({ data: { reply: 'Healthy.' } });
    const history = [{ role: 'user', content: 'Hi' }];

    const data = await askAi('Is prod healthy?', history);

    expect(post).toHaveBeenCalledWith('/api/ai/chat', { message: 'Is prod healthy?', history });
    expect(data.reply).toBe('Healthy.');
  });
});

describe('extractErrorMessage', () => {
  it('uses the service detail when there is one', () => {
    expect(extractErrorMessage({ response: { data: { detail: 'Access denied' } } })).toBe('Access denied');
  });

  it('explains timeouts and network errors', () => {
    expect(extractErrorMessage({ code: 'ECONNABORTED' })).toMatch(/timed out/);
    expect(extractErrorMessage({ message: 'Network Error' })).toMatch(/Cannot reach/);
  });

  it('joins validation errors and falls back otherwise', () => {
    expect(extractErrorMessage({ response: { data: { detail: [{ msg: 'a' }, { msg: 'b' }] } } })).toBe('a, b');
    expect(extractErrorMessage({}, 'fallback')).toBe('fallback');
  });
});
