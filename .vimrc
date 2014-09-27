" to enable this, see http://drupal.dev.andrewsharpe.info/node/17
" we need to use BufWinEnter since it's run after BufReadPost which is where
" we hook into the startup process (unfortunately)

" indents are two spaces, no tabs, and backspace will eat two spaces if it can
au BufWinEnter *.coffee setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab
" make comments easy on the eye
au BufWinEnter *.coffee hi comment ctermfg=22

