" to enable this, see http://drupal.dev.andrewsharpe.info/node/17
" we need to use BufWinEnter since it's run after BufReadPost which is where
" we hook into the startup process (unfortunately)
"
" NOTE: you should only put formatting consistency settings in this file, if
" you want some view specific features (eg. colours) then use .vimrc.local

" load up the local (not in git) version if it exists
let s:current_file=expand('<sfile>')
if filereadable(s:current_file . '.local')
	execute 'source ' . s:current_file . '.local'
endif

" load the consistency settings last in a feeble attempt to ensure the code
" is consistent

" indents are two spaces, no tabs, and backspace will eat two spaces if it can
au BufWinEnter *.coffee setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab

