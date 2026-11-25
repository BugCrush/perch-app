// /perch: the Perch task board of this machine in a menu inside this Claude Code session.
// Browsing costs no usage: the menu talks only to the Perch host on this machine (loopback,
// /local/perch/...). Starting a task sends one ordinary message into this conversation;
// the host links the card to this session exactly as the phone's Run does, and moves it to
// Review when Claude's answer is in.
//
// Part of the Perch plugin: installed with `/plugin install perch@perch` (or by
// `perch_host commands install`). The host's port is read from the `port` file `serve`
// writes into its state folder (PERCH_STATE_DIR, else %APPDATA%/perch, else ~/.perch).
import type { EngineInterface, Register } from 'claude-code'

const PANE = 'perch'

type Column = { column: string; label: string }
type Check = { text: string; met?: boolean }
type Todo = { text: string; done: boolean }
type Report = { text: string; criteria?: Check[]; todos: Todo[]; files: string[]; changes: string[] }
type Task = {
  id: string
  title: string
  description: string
  cwd: string
  acceptance?: string[]
  column: string
  columnLabel: string
  priority: string
  priorityLabel: string
  typeLabel?: string | null
  machine: string
  sessionName?: string
  linkedHere: boolean
  canStart: boolean
  report?: Report
}
type Project = {
  id: string
  name: string
  folder: string
  here: boolean
  count: number
  columns: (Column & { tasks: Task[] })[]
}
type Board = {
  machine: string
  cwd: string
  session: { id: string; name: string; state: string; live: boolean } | null
  projects: Project[]
  columns: Column[]
  taskTypes: { id: string; label: string }[]
  priorities: { id: string; label: string }[]
}
type View =
  | { kind: 'home' }
  | { kind: 'project'; project: string }
  | { kind: 'task'; task: string; project: string }
  | { kind: 'move'; task: string; project: string }
  | { kind: 'add'; project: string }
  | { kind: 'pair' }
  | { kind: 'invite' }
/**
 * What the host says about this machine: paired yet, (macOS) the Accessibility permission,
 * and why the relay refuses it (an invite code missing or wrong, the shared pool used up).
 */
type Status = {
  machine: string
  version: string
  paired: boolean
  accessibility?: boolean
  accessibilityHelp?: string
  relayRefusal?: string
  relayRefusalText?: string
}
/** The relay wants an invite code from this machine. */
const needsInvite = (s: Status | null) => s?.relayRefusal !== undefined && s.relayRefusal.startsWith('invite')
type Draft = { title: string; description: string; acceptance: string; taskType: string; priority: string }

const emptyDraft = (): Draft => ({ title: '', description: '', acceptance: '', taskType: '', priority: 'normal' })

// The menu's state lives with the open pane; a new /perch starts it again.
let board: Board | null = null
let view: View = { kind: 'home' }
let note = ''
let busy = false
let draft: Draft = emptyDraft()
let here = { session: '', cwd: '' }
let status: Status | null = null
let pairing: { link: string; qr: string } | null = null
let inviteCode = ''

type Engine = EngineInterface

let port = 8787

// The port the Perch host on this machine listens on: the state folder's `port` file, 8787
// when there is none (the same rule as the plugin's hooks).
async function hostPort($: Engine): Promise<number> {
  const own = await $.env.get('PERCH_STATE_DIR')
  const appData = await $.env.get('APPDATA')
  const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? ''
  const dir = own ? own : appData ? `${appData}/perch` : `${home}/.perch`
  try {
    const n = Number((await $.fs.read(`${dir}/port`)).trim())
    if (Number.isInteger(n) && n > 0 && n < 65536) return n
  } catch {
    // no port file: the default port
  }
  return 8787
}

async function api(
  $: Engine,
  action: string,
  body?: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const query =
    action === 'board'
      ? `?session=${encodeURIComponent(here.session)}&cwd=${encodeURIComponent(here.cwd)}`
      : ''
  let r
  port = await hostPort($)
  try {
    r = await $.http.fetch(`http://127.0.0.1:${port}/local/perch/${action}${query}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'x-perch-menu': '1', 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify({ session: here.session, cwd: here.cwd, ...body }),
    })
  } catch {
    throw new Error(`The Perch host is not running on this machine (port ${port}). Start it, then open /perch again.`)
  }
  let j: Record<string, unknown> = {}
  try {
    j = JSON.parse(r.text) as Record<string, unknown>
  } catch {
    j = {}
  }
  if (!r.ok) {
    const why = typeof j.error === 'string' ? j.error : `The Perch host answered ${r.status}.`
    throw new Error(r.status === 403 && !j.error ? `The Perch host on port ${port} refused the menu (${r.status}).` : why)
  }
  return j
}

function redraw($: Engine) {
  $.ui.invalidate('ui.render')
}

async function reload($: Engine) {
  try {
    status = (await api($, 'status')) as unknown as Status
  } catch {
    status = null
  }
  board = (await api($, 'board')) as unknown as Board
}

/** At the start of a session: one quiet line when the machine still needs something. */
async function startNote($: Engine) {
  try {
    const s = (await api($, 'status')) as unknown as Status
    if (!s.paired) $.ui.toast('Perch: no phone is paired with this machine yet. Open /perch to pair one.', { timeoutMs: 8000 })
    if (s.accessibility === false && s.accessibilityHelp) $.ui.toast(s.accessibilityHelp, { timeoutMs: 12000 })
    if (needsInvite(s)) $.ui.toast(`Perch: ${s.relayRefusalText ?? 'the relay needs an invite code'}. Open /perch to enter it.`, { timeoutMs: 12000 })
  } catch {
    // No host yet (the plugin may still be installing it): nothing to say.
  }
}

/** Runs an action of the menu: one at a time, its error shown on the menu. */
async function act($: Engine, work: () => Promise<void>) {
  if (busy) return
  busy = true
  note = ''
  redraw($)
  try {
    await work()
  } catch (e) {
    note = e instanceof Error ? e.message : String(e)
  } finally {
    busy = false
    redraw($)
  }
}

/**
 * Where Move to… can take a task: any other column but In progress, which only starting
 * the task reaches (as on the board, where dropping a card there opens Run).
 */
const movable = (to: string, from: string) => to !== from && to !== 'inProgress'

/** The element the focus ring starts on in a view (the ring would stay where it was). */
function firstKey(v: View): string | undefined {
  if (v.kind === 'pair') return 'back'
  if (v.kind === 'invite') return 'code'
  if (board === null) return 'retry'
  switch (v.kind) {
    case 'home': {
      const p = board.projects[0]
      return p === undefined ? 'close' : `p:${p.id}`
    }
    case 'project': {
      for (const c of projectOf(v.project)?.columns ?? []) {
        const t = c.tasks[0]
        if (t !== undefined) return `t:${t.id}`
      }
      return projectOf(v.project)?.here ? 'add' : 'back'
    }
    case 'task': {
      const t = taskOf(v.task)
      return t?.canStart && board.session !== null ? 'start' : 'back'
    }
    case 'move':
      return `m:${board.columns.find(c => movable(c.column, taskOf(v.task)?.column ?? ''))?.column ?? ''}`
    case 'add':
      return 'title'
  }
}

/** Shows view [v] with the focus ring on its first element. */
function show($: Engine, v: View) {
  view = v
  redraw($)
  const key = firstKey(v)
  if (key !== undefined) $.ui.focus({ requestId: PANE, key }).catch(() => undefined)
}

const projectOf = (id: string) => board?.projects.find(p => p.id === id)
const taskOf = (id: string) => {
  for (const p of board?.projects ?? []) for (const c of p.columns) for (const t of c.tasks) if (t.id === id) return t
  return undefined
}
const counts = (p: Project) => p.columns.map(c => `${c.label} ${c.tasks.length}`).join(' · ')
const mark = (t: Task) => (t.priority === 'high' ? '! ' : t.priority === 'low' ? '- ' : '  ')
const cut = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s)
const lines = (s: string, n: number) => {
  const all = s.replace(/\r/g, '').split('\n')
  return all.length > n ? [...all.slice(0, n), `… ${all.length - n} more lines (open the task on the phone or the board page)`] : all
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'perch',
      description: 'Perch task board: browse tasks, start one in this session, add or move tasks; pair a phone',
    })
    here = { session: await $.session.id(), cwd: await $.session.cwd() }
    void startNote($)
    return next(e)
  })

  on('command.run', { command: 'perch' }, async $ => {
    here = { session: await $.session.id(), cwd: await $.session.cwd() }
    view = { kind: 'home' }
    note = ''
    busy = false
    draft = emptyDraft()
    board = null
    pairing = null
    try {
      await reload($)
    } catch (e) {
      note = e instanceof Error ? e.message : String(e)
    }
    // As tall as the terminal spares (a third when left out): the board needs room.
    await $.ui.open({ id: PANE, title: 'Perch', focus: true, closeOnEscape: true, holdToasts: true, rows: 60 })
    show($, { kind: 'home' })
    return {}
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Input, Select, Markdown } = $.ui.resolve(e)
    const width = Math.max(30, (e.props as { bodyColumns?: number }).bodyColumns ?? e.viewport?.columns ?? 80)
    const go = (v: View) => () => {
      note = ''
      show($, v)
    }
    const close = () => void $.ui.close({ id: PANE })
    const header = (
      <Box flexDirection="column">
        <Text bold>
          Perch · {board?.machine ?? 'this machine'}
          {busy ? ' · working…' : ''}
        </Text>
        <Text dimColor wrap="truncate-end">
          {board === null
            ? ''
            : board.session
              ? `This session: ${board.session.name}`
              : 'Perch does not see this session yet: browsing works, starting a task here does not.'}
        </Text>
        {note !== '' && <Text color="warning">{note}</Text>}
      </Box>
    )

    if (view.kind === 'pair') {
      return (
        <Box flexDirection="column">
          {header}
          <Text> </Text>
          {pairing === null ? (
            <Text dimColor>{busy ? 'Asking the host for the pairing code…' : 'No pairing code.'}</Text>
          ) : (
            <Box flexDirection="column">
              <Text>Scan this code with your phone's camera (or in the Perch app: Add machine):</Text>
              <Text>{pairing.qr}</Text>
              <Text dimColor>Or paste this link in the app (keep it private: it lets a device ask to pair):</Text>
              <Text wrap="wrap">{pairing.link}</Text>
              <Text> </Text>
              <Text>
                Then allow the phone at this machine: the Perch host's window (A), its dialog, or perch_host devices allow.
              </Text>
            </Box>
          )}
          <Text> </Text>
          <Button
            key="back"
            onPress={() => {
              pairing = null
              show($, { kind: 'home' })
            }}
          >
            Back
          </Button>
        </Box>
      )
    }
    const pairButton = (
      <Button
        key="pair"
        onPress={() => {
          show($, { kind: 'pair' })
          void act($, async () => {
            pairing = (await api($, 'pairing')) as unknown as { link: string; qr: string }
          })
        }}
      >
        {status !== null && !status.paired ? 'Pair your phone' : 'Pair another phone'}
      </Button>
    )
    if (view.kind === 'invite') {
      return (
        <Box flexDirection="column">
          {header}
          <Text> </Text>
          <Text wrap="wrap">
            The relay lets your phone reach this machine away from home. Type the invite code you were sent (perch-…).
          </Text>
          <Input
            key="code"
            label="Invite code"
            placeholder="perch-xxxx-xxxx-xxxx"
            value={inviteCode}
            autoFocus
            onInput={v => {
              inviteCode = v
            }}
            onSubmit={v => {
              inviteCode = v
            }}
          />
          <Button
            key="save-code"
            variant="primary"
            onPress={() =>
              act($, async () => {
                // The host connects again with the code and waits a few seconds for the relay.
                const res = await api($, 'invite', { code: inviteCode })
                inviteCode = ''
                await reload($)
                note =
                  res.accepted === true
                    ? 'Invite code saved: the relay accepted this machine.'
                    : typeof res.refusal === 'string'
                      ? `Relay: ${res.refusal}.`
                      : 'Invite code saved; the relay has not answered yet.'
                show($, { kind: 'home' })
              })
            }
          >
            Save
          </Button>
          <Button key="back" onPress={go({ kind: 'home' })}>
            Back
          </Button>
        </Box>
      )
    }
    const inviteButton = (
      <Button key="invite" onPress={go({ kind: 'invite' })}>
        Enter invite code
      </Button>
    )
    const machineNotes = (
      <Box flexDirection="column">
        {status?.relayRefusalText && (
          <Text color="warning" wrap="wrap">
            {`Relay: ${status.relayRefusalText}.`}
          </Text>
        )}
        {status !== null && !status.paired && <Text color="warning">No phone is paired with this machine yet.</Text>}
        {status?.accessibility === false && status.accessibilityHelp && (
          <Text color="warning" wrap="wrap">
            {status.accessibilityHelp}
          </Text>
        )}
      </Box>
    )

    if (board === null) {
      return (
        <Box flexDirection="column">
          {header}
          {machineNotes}
          {needsInvite(status) && inviteButton}
          {status !== null && pairButton}
          <Button key="retry" onPress={() => act($, () => reload($))}>
            Try again
          </Button>
          <Button key="close" onPress={close}>
            Close
          </Button>
        </Box>
      )
    }

    if (view.kind === 'project' || view.kind === 'add' || view.kind === 'task' || view.kind === 'move') {
      if (!projectOf(view.project)) view = { kind: 'home' }
    }
    if ((view.kind === 'task' || view.kind === 'move') && !taskOf(view.task)) {
      view = { kind: 'project', project: view.project }
    }

    if (view.kind === 'home') {
      const first = board.projects[0]
      return (
        <Box flexDirection="column">
          {header}
          {machineNotes}
          <Text> </Text>
          <Text dimColor>Projects (this folder's first):</Text>
          {board.projects.map((p, i) => (
            <Button key={`p:${p.id}`} plain onPress={go({ kind: 'project', project: p.id })}>
              {`${i < 9 ? `${i + 1}. ` : '   '}${p.name}${p.here ? ' (this folder)' : ''}  `}
              <Text dimColor>{cut(counts(p), Math.max(10, width - p.name.length - 22))}</Text>
            </Button>
          ))}
          <Text> </Text>
          {first !== undefined && first.here && (
            <Button key="add" onPress={go({ kind: 'add', project: first.id })}>
              {`Add a task to ${first.name}`}
            </Button>
          )}
          {needsInvite(status) && inviteButton}
          {pairButton}
          <Button key="close" onPress={close}>
            Close
          </Button>
          <Text dimColor>Arrows or Tab to move, Enter to open, Esc to close. Browsing uses no Claude usage.</Text>
        </Box>
      )
    }

    if (view.kind === 'project') {
      const p = projectOf(view.project)!
      const pid = p.id
      return (
        <Box flexDirection="column">
          {header}
          <Text> </Text>
          <Text bold>{p.name}</Text>
          <Text dimColor wrap="truncate-middle">
            {p.folder}
          </Text>
          {p.columns.map(c => {
            const shown = c.column === 'done' ? c.tasks.slice(0, 5) : c.tasks
            return (
              <Box key={`c:${c.column}`} flexDirection="column" marginTop={1}>
                <Text bold>{`${c.label} (${c.tasks.length})`}</Text>
                {c.tasks.length === 0 && <Text dimColor>  none</Text>}
                {shown.map(t => (
                  <Button key={`t:${t.id}`} plain onPress={go({ kind: 'task', task: t.id, project: pid })}>
                    {`${mark(t)}${cut(t.title, Math.max(20, width - 30))}`}
                    <Text dimColor>
                      {[t.typeLabel, t.linkedHere ? 'this session' : t.sessionName].filter(Boolean).length > 0
                        ? `  ${[t.typeLabel, t.linkedHere ? 'this session' : t.sessionName].filter(Boolean).join(' · ')}`
                        : ''}
                    </Text>
                  </Button>
                ))}
                {shown.length < c.tasks.length && <Text dimColor>{`  … ${c.tasks.length - shown.length} more`}</Text>}
              </Box>
            )
          })}
          <Text> </Text>
          {p.here && (
            <Button key="add" onPress={go({ kind: 'add', project: pid })}>
              Add a task here
            </Button>
          )}
          <Button key="back" onPress={go({ kind: 'home' })}>
            Back
          </Button>
        </Box>
      )
    }

    if (view.kind === 'task' || view.kind === 'move') {
      const t = taskOf(view.task)!
      const pid = view.project
      const tid = t.id
      const r = t.report
      const checks = r?.criteria ?? (t.acceptance ?? []).map(text => ({ text }) as Check)
      if (view.kind === 'move') {
        return (
          <Box flexDirection="column">
            {header}
            <Text> </Text>
            <Text bold>{`Move "${cut(t.title, width - 12)}" to:`}</Text>
            {board.columns
              .filter(c => movable(c.column, t.column))
              .map(c => (
                <Button
                  key={`m:${c.column}`}
                  plain
                  onPress={() =>
                    act($, async () => {
                      await api($, 'move', { taskId: tid, column: c.column })
                      await reload($)
                      note = `Moved to ${c.label}.`
                      show($, { kind: 'task', task: tid, project: pid })
                    })
                  }
                >
                  {c.label}
                </Button>
              ))}
            <Button key="back" onPress={go({ kind: 'task', task: tid, project: pid })}>
              Back
            </Button>
          </Box>
        )
      }
      const finish = (column: 'review' | 'done', label: string) => () =>
        act($, async () => {
          await api($, 'finish', { taskId: tid, column })
          await reload($)
          note = label
        })
      return (
        <Box flexDirection="column">
          {header}
          <Text> </Text>
          <Text bold>{t.title}</Text>
          <Text dimColor wrap="truncate-end">
            {[t.columnLabel, `${t.priorityLabel} priority`, t.typeLabel ?? 'No type', t.machine].join(' · ')}
          </Text>
          <Text dimColor wrap="truncate-middle">
            {t.cwd}
          </Text>
          <Text dimColor>
            {t.linkedHere ? 'Linked to this session' : t.sessionName ? `Linked to ${t.sessionName}` : 'Not started yet'}
          </Text>
          {t.description.trim() !== '' && (
            <Box flexDirection="column" marginTop={1}>
              <Markdown text={lines(t.description.trim(), 20).join('\n')} />
            </Box>
          )}
          {checks.length > 0 && (
            <Box flexDirection="column" marginTop={1}>
              <Text bold>Acceptance criteria</Text>
              {checks.map((c, i) => (
                <Text>{`${c.met === true ? '[x]' : c.met === false ? '[ ]' : ` ${i + 1}.`} ${c.text}`}</Text>
              ))}
            </Box>
          )}
          {r !== undefined && (
            <Box flexDirection="column" marginTop={1}>
              {/^#+\s*report\b/i.test(r.text.trim()) ? null : <Text bold>Report</Text>}
              <Markdown text={lines(r.text.trim() || '(no report text)', 24).join('\n')} />
              {r.todos.length > 0 && (
                <Text dimColor>{`To-do: ${r.todos.filter(x => x.done).length} of ${r.todos.length} done`}</Text>
              )}
              {r.files.length > 0 && (
                <Text dimColor wrap="truncate-end">{`Files: ${r.files.map(f => f.split(/[\\/]/).pop()).join(', ')}`}</Text>
              )}
              {r.changes.slice(0, 6).map(c => (
                <Text dimColor wrap="truncate-end">
                  {c}
                </Text>
              ))}
            </Box>
          )}
          <Text> </Text>
          {t.canStart && board.session !== null && (
            <Button
              key="start"
              variant="primary"
              onPress={() =>
                act($, async () => {
                  const res = await api($, 'start', { taskId: tid })
                  const prompt = String(res.prompt ?? '')
                  await $.ui.close({ id: PANE })
                  await $.prompt.submit({ text: prompt, asUser: true })
                  $.ui.toast(`Perch: started "${t.title}" in this session`)
                })
              }
            >
              Start in this session
            </Button>
          )}
          {board.session !== null && t.column !== 'review' && t.column !== 'done' && (
            <Button key="review" onPress={finish('review', "Sent to Review with this session's report.")}>
              Send to Review with this session's report
            </Button>
          )}
          {board.session !== null && t.column !== 'done' && (
            <Button key="done" onPress={finish('done', "Marked done with this session's report.")}>
              Mark done with this session's report
            </Button>
          )}
          <Button key="move" onPress={go({ kind: 'move', task: tid, project: pid })}>
            Move to…
          </Button>
          <Button key="back" onPress={go({ kind: 'project', project: pid })}>
            Back
          </Button>
        </Box>
      )
    }

    // Add a task to this folder's project.
    const p = projectOf(view.project)!
    const pid = p.id
    const typeOptions = [{ value: '', label: 'No type' }, ...board.taskTypes.map(x => ({ value: x.id, label: x.label }))]
    const priorityOptions = board.priorities.map(x => ({ value: x.id, label: x.label }))
    const set = (k: keyof Draft) => (v: string) => {
      draft = { ...draft, [k]: v }
    }
    return (
      <Box flexDirection="column">
        {header}
        <Text> </Text>
        <Text bold>{`New task in ${p.name}`}</Text>
        <Input key="title" label="Title" placeholder="What to do" value={draft.title} autoFocus onInput={set('title')} onSubmit={set('title')} />
        <Input
          key="description"
          label="Description"
          placeholder="As Claude should read it"
          rows={3}
          value={draft.description}
          onInput={set('description')}
          onSubmit={set('description')}
        />
        <Input
          key="acceptance"
          label="Acceptance criteria"
          placeholder="One per line"
          rows={3}
          value={draft.acceptance}
          onInput={set('acceptance')}
          onSubmit={set('acceptance')}
        />
        <Select key="type" label="Type" options={typeOptions} value={draft.taskType} onSelect={v => set('taskType')(v)} />
        <Select key="priority" label="Priority" options={priorityOptions} value={draft.priority} onSelect={v => set('priority')(v)} />
        <Text> </Text>
        <Button
          key="save"
          variant="primary"
          onPress={() =>
            act($, async () => {
              const res = await api($, 'add', {
                title: draft.title,
                description: draft.description,
                acceptance: draft.acceptance,
                taskType: draft.taskType === '' ? null : draft.taskType,
                priority: draft.priority,
              })
              await reload($)
              const added = res.task as Task | undefined
              draft = emptyDraft()
              note = `Added "${added?.title ?? 'the task'}" to Backlog.`
              show($, { kind: 'project', project: board?.projects[0]?.id ?? pid })
            })
          }
        >
          Add to Backlog
        </Button>
        <Button key="cancel" onPress={go({ kind: 'project', project: pid })}>
          Cancel
        </Button>
      </Box>
    )
  })
}
