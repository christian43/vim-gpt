
" ===================================================
" GPT-5 Integration für Vim (Responses API + Web Search)
" ===================================================

let s:gpt_previous_response_id = ''
let s:gpt_response_lines = []

" ---------------------------------------------------
" GPT-Buffer finden und Text anhängen
" ---------------------------------------------------
function! s:AppendToGPTBuffer(lines) abort
  for l:buf in getbufinfo()
    if has_key(l:buf.variables,'is_gpt_buffer') && l:buf.variables.is_gpt_buffer
      call bufload(l:buf.bufnr)
      call appendbufline(l:buf.bufnr,'$',a:lines)
      return
    endif
  endfor
  echoerr "GPT-Buffer nicht gefunden! Bitte :call GPTOpen() zuerst."
endfunction

" ---------------------------------------------------
" GPT-Ausgabefenster öffnen/aktivieren
" ---------------------------------------------------
function! GPTOpen()
  for l:buf in getbufinfo()
    if has_key(l:buf.variables,'is_gpt_buffer') && l:buf.variables.is_gpt_buffer
      execute 'buffer' l:buf.bufnr
      return
    endif
  endfor

  vert botright new GPT_Output
  setlocal buftype=nofile bufhidden=hide nobuflisted noswapfile
  let b:is_gpt_buffer = 1
  setlocal syntax=enable

  call setline(1,['User:',''])
endfunction

" ---------------------------------------------------
" Prompt-Profile
" ---------------------------------------------------
if !exists('g:gpt_prompts')
  let g:gpt_prompts = {
        \ 'default': 'Gib kurze, sachliche, faktenbasierte Antworten. Maximal 60 Wörter oder 4 Bullet-Points. Direkt auf die Frage antworten, ohne Einleitung oder Wiederholungen. Text in Markdown. Code nur wenn nötig, minimal, in Codefences mit Sprachangabe (z. B. ```r). Bei Unklarheit: genau 1 Rückfrage.',
        \ 'summary': 'Summarize the following text clearly and briefly, focusing on key facts.',
        \ 'code': 'Explain or generate code clearly, using Markdown fenced code blocks.',
        \ 'translate': 'Translate the text into clear, natural German, preserving meaning and tone.',
        \ 'analyze': 'Critically analyze the content, referencing scientific reasoning where appropriate.'
        \ }
endif
if !exists('g:gpt_active_prompt')
  let g:gpt_active_prompt = 'default'
endif
command! -nargs=1 GPTSetPrompt call GPTSetPrompt(<f-args>)
function! GPTSetPrompt(name) abort
  if has_key(g:gpt_prompts,a:name)
    let g:gpt_active_prompt = a:name
    echo "Aktiver Prompt: ".a:name
  else
    echoerr "Unbekannter Prompt: ".a:name." (verfügbar: ".join(keys(g:gpt_prompts),', ').")"
  endif
endfunction

" ---------------------------------------------------
" Auswahl oder Zeile senden, Antwort anhängen
" ---------------------------------------------------
function! GPTSendLines() range
  let s:gpt_response_lines = []

  " Gesamten User-Block erfassen
  let l:buf_lines = getline(1,'$')
  let l:user_start = -1
  let l:user_end = len(l:buf_lines)
  for l:i in range(len(l:buf_lines)-1,-1,-1)
    if l:buf_lines[l:i] =~ '^GPT:'
      let l:user_end = l:i-1
    endif
    if l:buf_lines[l:i] =~ '^User:'
      let l:user_start = l:i
      break
    endif
  endfor
  if l:user_start >= 0
    let l:user_input = join(l:buf_lines[l:user_start:l:user_end],"\n")
  else
    let l:user_input = ''
  endif
  if empty(l:user_input)
    echo "Keine Eingabe!"
    return
  endif

  " ---------------------------------------------------
  " Payload bauen (Responses API + Web Search)
  " ---------------------------------------------------
" Fr, 09.10.2026 15:53:10 (CEST) 
" let l:base_payload = {
"     \ 'model': 'gpt-6.1-sol',
"     \ 'instructions': get(g:gpt_prompts, g:gpt_active_prompt, g:gpt_prompts['default']) 
"     \   . "\nDu bist ein wissenschaftlicher Assistent. Antworte präzise, faktenbasiert und objektiv."
"     \   . "\nNutze das Websuche-Tool NUR, wenn die Benutzeranfrage aktuelle Ereignisse, Echtzeitdaten oder dir unbekannte Fakten betrifft. Generiere Antworten zu Logik, Code oder allgemeinem Wissen direkt ohne Websuche.",
"     \ 'input': [
"     \   {'role': 'user', 'content': substitute(l:user_input, "^User:\\s*", "", "")}
"     \ ],
"     \ 'reasoning': {'effort': 'low'},
"     \ 'tools': [{'type': 'web_search'}],
"     \ 'tool_choice': 'auto'
"     \ }
" 1. Prüfe, ob die Eingabe mit einem Such-Präfix (z. B. '!') beginnt
let l:clean_input = substitute(l:user_input, "^User:\\s*", "", "")
let l:needs_search = 0

if l:clean_input =~ '^!'
    let l:needs_search = 1
    " Entferne das Ausrufezeichen und führende Leerzeichen für die API-Anfrage
    let l:clean_input = substitute(l:clean_input, "^!\\s*", "", "")
endif

" 2. Erstelle den Basis-Payload (ohne Tools)
let l:base_payload = {
    \ 'model': 'gpt-6.1-sol',
    \ 'instructions': get(g:gpt_prompts, g:gpt_active_prompt, g:gpt_prompts['default']) . "\nDu bist ein wissenschaftlicher Assistent. Antworte präzise, faktenbasiert und objektiv.",
    \ 'input': [
    \   {'role': 'user', 'content': l:clean_input}
    \ ],
    \ 'reasoning': {'effort': 'low'}
    \ }

" 3. Hänge das Web-Tool NUR an, wenn das Präfix erkannt wurde
if l:needs_search
    let l:base_payload['tools'] = [{'type': 'web_search'}]
    let l:base_payload['tool_choice'] = 'auto'
    " Optional: Dem Modell im Prompt sagen, dass es jetzt suchen MUSS
    let l:base_payload['instructions'] .= "\nNutze das Websuche-Tool, um die Anfrage mit aktuellen Webquellen abzusichern."
endif

  " previous_response_id für laufenden Kontext
  if !empty(s:gpt_previous_response_id)
    let l:base_payload['previous_response_id'] = s:gpt_previous_response_id
  endif

  let l:payload = json_encode(l:base_payload)

  " ---------------------------------------------------
  " Callbacks
  " ---------------------------------------------------
  function! s:OnOut(ch,msg) abort
    if type(a:msg) == type('')
      call add(s:gpt_response_lines, a:msg)
    elseif type(a:msg) == type([])
      call extend(s:gpt_response_lines, a:msg)
    endif
  endfunction

  function! s:OnExit(job_id, code) abort
    let l:resp = join(filter(copy(s:gpt_response_lines),'type(v:val)==type("")'),"\n")
    if empty(l:resp)
      call s:AppendToGPTBuffer(['GPT-5: Keine Antwort oder Fehler.',''])
      return
    endif

    try
      let l:json = json_decode(l:resp)
    catch
      call s:AppendToGPTBuffer(['GPT-5: Fehler beim Parsen (ungültiges JSON).',''])
      return
    endtry

    if has_key(l:json,'error') && !empty(l:json.error)
      call s:AppendToGPTBuffer(['GPT-5 Error: '.l:json.error.message])
      return
    endif

    " Response-ID speichern für nächsten Aufruf
    if has_key(l:json,'id')
      let s:gpt_previous_response_id = l:json.id
    endif

    " Antwort extrahieren
    let l:texts = []
    if has_key(l:json,'output')
      for l:item in l:json.output
        if has_key(l:item,'content')
          for l:c in l:item.content
            if has_key(l:c,'text') && (get(l:c,'type','')=='output_text' || get(l:c,'type','')=='text')
              call add(l:texts, l:c.text)
            endif
          endfor
        endif
      endfor
    endif

    let l:decoded = []
    for l:t in l:texts
      let l:t = substitute(l:t,'\r','','g')
      let l:t = substitute(l:t,'\\n',"\n",'g')
      let l:t = substitute(l:t,'\v\\u([0-9A-Fa-f]{4})','\=nr2char("0x".submatch(1))','g')
      call add(l:decoded, iconv(l:t,'utf-8',&encoding))
    endfor

    let l:answer = join(l:decoded,"\n")
    let l:out_lines = split(l:answer,"\n")
let l:prefix = 'GPT: ['.get(l:json, 'model', 'unbekannt').']'
if !empty(l:out_lines)
  let l:out_lines[0] = l:prefix.' '.l:out_lines[0]
else
  let l:out_lines = [l:prefix]
"     if !empty(l:out_lines)
"       let l:out_lines[0] = 'GPT-5: '.l:out_lines[0]
"     else
"       let l:out_lines = ['GPT-5:']
    endif

    call s:AppendToGPTBuffer(['']+l:out_lines+['','User:'])
  endfunction

  " ---------------------------------------------------
  " API-Request starten
  " ---------------------------------------------------
  let l:cmd = [
        \ 'curl','--http2','--no-buffer','-s',
        \ '-H','Content-Type: application/json',
        \ '-H','Authorization: Bearer '. $OPENAI_API_KEY,
        \ '-d', l:payload,
        \ 'https://api.openai.com/v1/responses'
        \ ]
  call job_start(l:cmd,{
        \ 'out_cb': function('s:OnOut'),
        \ 'err_cb': function('s:OnOut'),
        \ 'exit_cb': function('s:OnExit')
        \ })
  echo "Sende Anfrage an GPT-5..."
endfunction

" ---------------------------------------------------
" Tastenkürzel
" ---------------------------------------------------
nnoremap <silent> <Leader>g :call GPTOpen()<CR>
vnoremap <silent> <Leader>aa :<C-U>call GPTSendLines()<CR>
nnoremap <silent> <Leader>aa vip:<C-U>call GPTSendLines()<CR>
