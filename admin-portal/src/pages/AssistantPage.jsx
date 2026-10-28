import { useEffect, useRef, useState } from 'react';
import PropTypes from 'prop-types';
import {
  Avatar,
  Box,
  Button,
  Chip,
  CircularProgress,
  IconButton,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import appConfig from '../config';
import { askAi, extractErrorMessage } from '../services/api';
import { ChatRounded as ChatRoundedIcon, SendRounded as SendRoundedIcon } from '../components/icons';
import { glassCard, goldGradient } from '../theme/theme';

const STORAGE_KEY = 'credpay.assistant.v1';
const HISTORY_TURNS = 10; // earlier messages sent along, so follow-up questions work

const SUGGESTIONS = [
  'Is prod healthy right now?',
  'Are any alerts firing? What should I do?',
  'Which pods use the most CPU and memory?',
  'Are there any problems in Dynatrace?',
  'Why could payments be slow?',
  'Give me a daily operations summary',
];

/**
 * "Ask CredAI": a chat with the AIOps service (ai-service, POST /api/ai/chat).
 * Each answer is written by Azure OpenAI from the live facts of this
 * environment - the Monitoring page's overview plus the facts that fit the
 * question (pods, events, CPU/memory, HTTP metrics).
 */
export default function AssistantPage() {
  if (!appConfig.aiopsEnabled) {
    return (
      <Box sx={{ animation: 'fadeInUp .4s ease both' }}>
        <Typography variant="h3" sx={{ mb: 0.5 }}>
          Ask CredAI
        </Typography>
        <Typography color="text.secondary" sx={{ maxWidth: 720 }}>
          The AI assistant runs in the prod environment, next to monitoring and AIOps. This environment does not run
          it.
        </Typography>
      </Box>
    );
  }
  return <Chat />;
}

function loadMessages() {
  try {
    return JSON.parse(sessionStorage.getItem(STORAGE_KEY)) || [];
  } catch {
    return [];
  }
}

function Chat() {
  // { id, role: 'user' | 'assistant', content, error?, sources? }
  const [messages, setMessages] = useState(loadMessages);
  const [input, setInput] = useState('');
  const [thinking, setThinking] = useState(false);
  const endRef = useRef(null);

  useEffect(() => {
    try {
      sessionStorage.setItem(STORAGE_KEY, JSON.stringify(messages));
    } catch {
      // storage unavailable (private window): the chat still works
    }
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [messages, thinking]);

  const add = (message) => setMessages((prev) => [...prev, { id: crypto.randomUUID(), ...message }]);

  const send = async (text) => {
    const question = text.trim();
    if (!question || thinking) return;
    const history = messages
      .filter((m) => !m.error)
      .slice(-HISTORY_TURNS)
      .map(({ role, content }) => ({ role, content }));
    add({ role: 'user', content: question });
    setInput('');
    setThinking(true);
    try {
      const data = await askAi(question, history);
      add({ role: 'assistant', content: data.reply, sources: data.sources });
    } catch (err) {
      add({ role: 'assistant', error: true, content: extractErrorMessage(err, 'CredAI could not answer. Please try again.') });
    } finally {
      setThinking(false);
    }
  };

  const onKeyDown = (event) => {
    // Enter sends, Shift+Enter starts a new line
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      send(input);
    }
  };

  return (
    <Box sx={{ animation: 'fadeInUp .4s ease both', display: 'flex', flexDirection: 'column', height: 'calc(100vh - 140px)' }}>
      <Stack direction="row" spacing={1.5} alignItems="center" sx={{ mb: 0.5, flexWrap: 'wrap' }}>
        <Typography variant="h3">Ask CredAI</Typography>
        <Box sx={{ flexGrow: 1 }} />
        {messages.length > 0 && (
          <Button size="small" variant="outlined" onClick={() => setMessages([])} disabled={thinking}>
            New chat
          </Button>
        )}
      </Stack>
      <Typography color="text.secondary" sx={{ mb: 2 }}>
        Ask about the health of this environment. Answers come from Azure OpenAI, using live data from Prometheus,
        Kubernetes, Alertmanager and Dynatrace.
      </Typography>

      <Paper elevation={0} sx={{ ...glassCard, flexGrow: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        {/* ---- Messages --------------------------------------------------- */}
        <Box sx={{ flexGrow: 1, overflowY: 'auto', p: { xs: 2, sm: 3 } }}>
          {messages.length === 0 ? (
            <Welcome onPick={send} />
          ) : (
            <Stack spacing={2}>
              {messages.map((m) => (
                <Message key={m.id} message={m} />
              ))}
              {thinking && (
                <Stack direction="row" spacing={1.5} alignItems="center">
                  <BotAvatar />
                  <CircularProgress size={18} />
                  <Typography color="text.secondary">CredAI is checking the live data…</Typography>
                </Stack>
              )}
            </Stack>
          )}
          <div ref={endRef} />
        </Box>

        {/* ---- Input ------------------------------------------------------- */}
        <Stack
          direction="row"
          spacing={1}
          alignItems="flex-end"
          sx={{ p: 2, borderTop: '1px solid', borderColor: 'divider' }}
        >
          <TextField
            fullWidth
            multiline
            maxRows={4}
            size="small"
            placeholder="Ask a question… (Enter to send, Shift+Enter for a new line)"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={onKeyDown}
            inputProps={{ maxLength: 2000, 'aria-label': 'Question for CredAI' }}
            autoFocus
          />
          <IconButton
            color="primary"
            onClick={() => send(input)}
            disabled={thinking || !input.trim()}
            aria-label="Send"
            sx={{ mb: 0.25 }}
          >
            <SendRoundedIcon />
          </IconButton>
        </Stack>
      </Paper>
    </Box>
  );
}

function Welcome({ onPick }) {
  return (
    <Stack alignItems="center" justifyContent="center" spacing={2} sx={{ height: '100%', textAlign: 'center', py: 4 }}>
      <BotAvatar size={56} />
      <Typography variant="h6">How can I help with this environment?</Typography>
      <Typography color="text.secondary" sx={{ maxWidth: 520 }}>
        Try one of these, or type your own question. Follow-up questions work too: CredAI remembers this
        conversation.
      </Typography>
      <Stack direction="row" spacing={1} useFlexGap sx={{ flexWrap: 'wrap', justifyContent: 'center', maxWidth: 720 }}>
        {SUGGESTIONS.map((s) => (
          <Chip key={s} label={s} variant="outlined" onClick={() => onPick(s)} />
        ))}
      </Stack>
    </Stack>
  );
}

Welcome.propTypes = { onPick: PropTypes.func.isRequired };

function BotAvatar({ size = 32 }) {
  return (
    <Avatar sx={{ width: size, height: size, background: goldGradient, color: '#0A0A0B' }}>
      <ChatRoundedIcon sx={{ fontSize: size * 0.55 }} />
    </Avatar>
  );
}

BotAvatar.propTypes = { size: PropTypes.number };

function bubbleStyle(message) {
  if (message.role === 'user') return { background: goldGradient, color: '#0A0A0B' };
  if (message.error) return { border: '1px solid', borderColor: 'error.main', color: 'error.main' };
  return { bgcolor: 'rgba(255,255,255,0.06)', border: '1px solid', borderColor: 'divider' };
}

function Message({ message }) {
  const mine = message.role === 'user';
  return (
    <Stack direction="row" spacing={1.5} justifyContent={mine ? 'flex-end' : 'flex-start'} alignItems="flex-start">
      {!mine && <BotAvatar />}
      <Box
        sx={{
          maxWidth: { xs: '85%', md: '75%' },
          px: 2,
          py: 1.25,
          borderRadius: mine ? '16px 16px 4px 16px' : '16px 16px 16px 4px',
          ...bubbleStyle(message),
        }}
      >
        {mine || message.error ? (
          <Typography sx={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{message.content}</Typography>
        ) : (
          <Answer text={message.content} />
        )}
        {message.sources?.length > 0 && (
          <Typography variant="caption" color="text.secondary" component="div" sx={{ mt: 1 }}>
            Based on: {message.sources.map((s) => s.name.replaceAll('_', ' ')).join(', ')}
          </Typography>
        )}
      </Box>
    </Stack>
  );
}

Message.propTypes = {
  message: PropTypes.shape({
    role: PropTypes.oneOf(['user', 'assistant']).isRequired,
    content: PropTypes.string.isRequired,
    error: PropTypes.bool,
    sources: PropTypes.arrayOf(PropTypes.shape({ name: PropTypes.string })),
  }).isRequired,
};

// ---- A small Markdown subset: ``` code blocks, "- " / "1. " lists, # headings, **bold**, `code` ----

/** Splits an answer into blocks: { id, type: 'code' | 'p' | 'h' | 'ul' | 'ol', text | items } */
function parseAnswer(text) {
  const blocks = [];
  let id = 0;
  let list = null;
  const add = (block) => blocks.push({ id: id++, ...block });
  const endList = () => {
    if (list) add(list);
    list = null;
  };

  text.split(/```[\w-]*\n?/).forEach((chunk, n) => {
    if (n % 2 === 1) {
      endList();
      add({ type: 'code', text: chunk.replace(/\n$/, '') });
      return;
    }
    for (const raw of chunk.split('\n')) {
      const line = raw.trim();
      const numbered = /^\d+\. /.test(line);
      if (numbered || /^[-*] /.test(line)) {
        const type = numbered ? 'ol' : 'ul';
        if (list?.type !== type) endList();
        list ??= { type, items: [] };
        list.items.push({ id: id++, text: line.slice(line.indexOf(' ') + 1) });
      } else {
        endList();
        if (/^#{1,4} /.test(line)) add({ type: 'h', text: line.slice(line.indexOf(' ') + 1) });
        else if (line) add({ type: 'p', text: line });
      }
    }
  });
  endList();
  return blocks;
}

function Answer({ text }) {
  return (
    <Box sx={{ '& > *:first-of-type': { mt: 0 }, '& > *:last-child': { mb: 0 } }}>
      {parseAnswer(text).map((block) => {
        if (block.type === 'code') {
          return (
            <Box
              key={block.id}
              component="pre"
              sx={{ my: 1, p: 1.5, borderRadius: '8px', bgcolor: 'rgba(0,0,0,0.35)', overflowX: 'auto', fontSize: 13 }}
            >
              <code>{block.text}</code>
            </Box>
          );
        }
        if (block.items) {
          return (
            <Box key={block.id} component={block.type} sx={{ my: 0.75, pl: 3 }}>
              {block.items.map((item) => (
                <Typography key={item.id} component="li" sx={{ my: 0.25, overflowWrap: 'anywhere' }}>
                  <Inline text={item.text} />
                </Typography>
              ))}
            </Box>
          );
        }
        return (
          <Typography
            key={block.id}
            sx={{ my: 0.75, fontWeight: block.type === 'h' ? 700 : undefined, overflowWrap: 'anywhere' }}
          >
            <Inline text={block.text} />
          </Typography>
        );
      })}
    </Box>
  );
}

Answer.propTypes = { text: PropTypes.string.isRequired };

/** **bold** and `code` inside one line */
function Inline({ text }) {
  const parts = [];
  let offset = 0;
  for (const part of text.split(/(\*\*[^*]+\*\*|`[^`]+`)/)) {
    const key = offset;
    offset += part.length;
    if (part.length > 4 && part.startsWith('**') && part.endsWith('**')) {
      parts.push(<strong key={key}>{part.slice(2, -2)}</strong>);
    } else if (part.length > 2 && part.startsWith('`') && part.endsWith('`')) {
      parts.push(
        <Box
          key={key}
          component="code"
          sx={{ px: 0.5, borderRadius: '4px', bgcolor: 'rgba(0,0,0,0.3)', fontSize: '0.9em', fontFamily: 'monospace' }}
        >
          {part.slice(1, -1)}
        </Box>,
      );
    } else if (part) {
      parts.push(<span key={key}>{part}</span>);
    }
  }
  return parts;
}

Inline.propTypes = { text: PropTypes.string.isRequired };
