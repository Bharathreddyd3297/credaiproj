import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import appConfig from '../src/config';
import { askAi } from '../src/services/api';
import AssistantPage from '../src/pages/AssistantPage';

// No backend in unit tests: the chat API is replaced by a mock
vi.mock('../src/services/api', () => ({
  askAi: vi.fn(),
  extractErrorMessage: (err, fallback) => err?.response?.data?.detail || fallback,
}));

const ANSWER = [
  '## Status',
  'Prod is **healthy**.',
  '- user-service: 0% errors',
  '- payment-service: 0% errors',
  '1. Open `Grafana`',
  '```bash',
  'kubectl get pods -n credpay-prod',
  '```',
].join('\n');

beforeEach(() => {
  appConfig.aiopsEnabled = true;
  sessionStorage.clear();
  Element.prototype.scrollIntoView = vi.fn(); // not implemented by jsdom
  askAi.mockReset();
});

afterEach(cleanup);

describe('Ask CredAI page', () => {
  it('explains that the assistant runs in prod only when AIOps is off', () => {
    appConfig.aiopsEnabled = false;
    render(<AssistantPage />);
    expect(screen.getByText(/runs in the prod environment/)).toBeTruthy();
    expect(screen.queryByLabelText('Question for CredAI')).toBeNull();
  });

  it('offers suggested questions', () => {
    render(<AssistantPage />);
    expect(screen.getByText('How can I help with this environment?')).toBeTruthy();
    expect(screen.getByText('Is prod healthy right now?')).toBeTruthy();
  });

  it('asks a suggested question and shows the formatted answer', async () => {
    askAi.mockResolvedValue({ reply: ANSWER, sources: [{ name: 'azure_openai' }, { name: 'kubernetes' }] });
    render(<AssistantPage />);

    fireEvent.click(screen.getByText('Is prod healthy right now?'));

    expect(await screen.findByText('Status')).toBeTruthy();
    expect(askAi).toHaveBeenCalledWith('Is prod healthy right now?', []);
    expect(screen.getByText('healthy').tagName).toBe('STRONG');
    expect(screen.getByText('user-service: 0% errors').closest('ul')).toBeTruthy();
    expect(screen.getByText('Open').closest('ol')).toBeTruthy();
    expect(screen.getByText('Grafana').tagName).toBe('CODE');
    expect(screen.getByText('kubectl get pods -n credpay-prod').closest('pre')).toBeTruthy();
    expect(screen.getByText('Based on: azure openai, kubernetes')).toBeTruthy();
  });

  it('sends the conversation so far with a follow-up question (Enter key)', async () => {
    askAi.mockResolvedValueOnce({ reply: 'All services are up.', sources: [] });
    askAi.mockResolvedValueOnce({ reply: 'payment-service uses the most CPU.', sources: [] });
    render(<AssistantPage />);
    const box = screen.getByLabelText('Question for CredAI');

    fireEvent.change(box, { target: { value: 'Is prod healthy?' } });
    fireEvent.keyDown(box, { key: 'Enter' });
    await screen.findByText('All services are up.');

    fireEvent.change(box, { target: { value: 'Which pod uses the most CPU?' } });
    fireEvent.click(screen.getByLabelText('Send'));
    await screen.findByText('payment-service uses the most CPU.');

    expect(askAi).toHaveBeenLastCalledWith('Which pod uses the most CPU?', [
      { role: 'user', content: 'Is prod healthy?' },
      { role: 'assistant', content: 'All services are up.' },
    ]);
  });

  it('shows the error when the assistant cannot answer, and New chat clears the conversation', async () => {
    askAi.mockRejectedValue({ response: { data: { detail: 'The assistant needs Azure OpenAI' } } });
    render(<AssistantPage />);

    fireEvent.click(screen.getByText('Are any alerts firing? What should I do?'));
    expect(await screen.findByText('The assistant needs Azure OpenAI')).toBeTruthy();

    fireEvent.click(screen.getByText('New chat'));
    expect(screen.queryByText('The assistant needs Azure OpenAI')).toBeNull();
    expect(screen.getByText('How can I help with this environment?')).toBeTruthy();
  });

  it('keeps the conversation when the page is opened again in the same tab', async () => {
    askAi.mockResolvedValue({ reply: 'Nothing to do.', sources: [] });
    const first = render(<AssistantPage />);
    fireEvent.click(screen.getByText('Is prod healthy right now?'));
    await screen.findByText('Nothing to do.');
    first.unmount();

    render(<AssistantPage />);
    expect(screen.getByText('Nothing to do.')).toBeTruthy();
  });
});
