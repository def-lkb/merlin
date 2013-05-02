import subprocess
import json
import vim
import re
import os
import sys

import vimbufsync
vimbufsync.check_version("0.1.0",who="merlin")

flags = []

enclosing_types = [] # nothing to see here
current_enclosing = -1

class MerlinExc(Exception):
  def __init__(self, value):
      self.value = value
  def __str__(self):
    return repr(self.value)

class Failure(MerlinExc):
  pass

class Error(MerlinExc):
  pass

class MerlinException(MerlinExc):
  pass

######## COMMUNICATION

mainpipe = None
saved_sync = None
def restart():
  global mainpipe
  if mainpipe:
    try:
      try:
        mainpipe.terminate()
      except OSError:
        pass
      mainpipe.communicate()
    except OSError:
      pass
  try:
    command = ["ocamlmerlin"]
    command.extend(flags)
    mainpipe = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None
        )
  except OSError as e:
    print("Failed to execute ocamlmerlin. Please ensure that ocamlmerlin binary\
            is in path and is executable.")
    raise e

def send_command(*cmd):
  global mainpipe
  if mainpipe == None or mainpipe.returncode != None:
    restart()
  json.dump(cmd, mainpipe.stdin)
  line = mainpipe.stdout.readline()
  result = json.loads(line)
  content = None
  if len(result) == 2:
    content = result[1]

  if result[0] == "return":
    return content
  elif result[0] == "failure":
    raise Failure(content)
  elif result[0] == "error":
    raise Error(content)
  elif result[0] == "exception":
    raise MerlinException(content)

def dump(*cmd):
  print(send_command('dump', *cmd))

def try_print_error(e, msg=None):
  try:
    raise e
  except Error as e:
    if msg: print(msg)
    else:
      print(e.value['message'])
  except Exception as e:
    if msg: print(msg)
    else:
      msg = str(e)
      if re.search('Chunk_parser.Error',msg):
        print ("error: Cannot parse")
        return None
      elif re.search('Not_found',msg):
        print ("error: Not found")
        return None
      m = re.search('Fl_package_base.No_such_package\("(([^"]|\\")*)", "(([^"]|\\")*)"\)',msg)
      if m:
        if m.group(3) != "":
          print ("error: Unknown package '%s' (%s)" % (m.group(1), m.group(3)))
        else:
          print ("error: Unknown package '%s'" % m.group(1))
        return None
      print(msg)

def catch_and_print(f, msg=None):
  try:
    return f()
  except MerlinException as e:
    try_print_error(e, msg=msg)

######## BASIC COMMANDS

def command_reload():
  return send_command("refresh")

def command_reset(name=None):
  global saved_sync
  if name:
    r = send_command("reset","name",name)
  else:
    r = send_command("reset")
  saved_sync = None
  return r

def command_tell(kind,content):
  if type(content) is list:
    return send_command("tell", kind, "\n".join(content) + "\n")
  else:
    return send_command("tell", kind, content)

def command_which_file(name):
  return send_command('which', 'path', name)

def command_which_with_ext(ext):
  return send_command('which', 'with_ext', ext)

def command_find_use(*packages):
  return send_command('find', 'use', *packages)

def command_find_list():
  return send_command('find', 'list')

def command_seek_before(line,col):
  position = send_command("seek", "before", {'line' : line, 'col': col})
  return (position['line'], position['col'])

def command_seek_exact(line,col):
  position = send_command("seek", "exact", {'line' : line, 'col': col})
  return (position['line'], position['col'])

def command_seek_scope():
  return send_command("seek", "maximize_scope")

def command_seek_end():
  return send_command("seek", "end")

def command_complete(base):
  return send_command("complete", "prefix", base)

def command_complete_cursor(base,line,col):
  return send_command("complete", "prefix", base, "at", {'line' : line, 'col': col})

def command_report_errors():
  return send_command("errors")

######## BUFFER SYNCHRONIZATION

def sync_buffer_to(to_line, to_col):
  global saved_sync
  curr_sync = vimbufsync.sync()
  cb = vim.current.buffer
  max_line = len(cb)
  end_line = min(to_line, max_line)

  if saved_sync and curr_sync.bufnr() == saved_sync.bufnr():
    line, col = saved_sync.pos()
    line, col = command_seek_before(line, col)
    if line <= 1:
      command_reset(name=os.path.basename(cb.name))
      content = cb[:end_line]
    else:
      rest    = cb[line-1][col:]
      content = cb[line:end_line]
      content.insert(0, rest)
  else:
    command_reset(name=os.path.basename(cb.name))
    content = cb[:end_line]
  saved_sync = curr_sync
  # Send content
  if content:
    kind = "struct"
    while not command_tell(kind,content):
      kind = "end"
      if end_line < max_line:
        next_end = min(max_line,end_line + 20)
        content = cb[end_line:next_end]
        end_line = next_end
      else:
        content = None
  # Now we are synced, come back to environment around cursor
  command_seek_exact(to_line, to_col)

def sync_buffer():
  to_line, to_col = vim.current.window.cursor
  sync_buffer_to(to_line, to_col)

def sync_full_buffer():
  sync_buffer_to(len(vim.current.buffer),0)

def vim_complete(base, vimvar):
  vim.command("let %s = []" % vimvar)
  sync_buffer()
  props = command_complete(base)
  for prop in props:
    vim.command("let l:tmp = {'word':'%s','menu':'%s','info':'%s','kind':'%s'}" %
      (prop['name'].replace("'", "''")
      ,prop['desc'].replace("\n"," ").replace("  "," ").replace("'", "''")
      ,prop['info'].replace("'", "''")
      ,prop['kind'][:1].replace("'", "''")
      ))
    vim.command("call add(%s, l:tmp)" % vimvar)

def vim_complete_cursor(base, vimvar):
  vim.command("let %s = []" % vimvar)
  line, col = vim.current.window.cursor
  sync_buffer()
  props = command_complete_cursor(base,line,col)
  for prop in props:
    vim.command("let l:tmp = {'word':'%s','menu':'%s','info':'%s','kind':'%s'}" %
      (prop['name'].replace("'", "''")
      ,prop['desc'].replace("\n"," ").replace("  "," ").replace("'", "''")
      ,prop['info'].replace("'", "''")
      ,prop['kind'][:1].replace("'", "''")
      ))
    vim.command("call add(%s, l:tmp)" % vimvar)

def vim_loclist(vimvar, ignore_warnings):
  vim.command("let %s = []" % vimvar)
  errors = command_report_errors()
  bufnr = vim.current.buffer.number
  nr = 0
  for error in errors:
    if error['type'] == 'warning' and vim.eval(ignore_warnings) == 'true':
        continue
    ty = 'w'
    if error['type'] == 'type' or error['type'] == 'parser':
      ty = 'e'
    lnum = 1
    lcol = 1
    if error.has_key('start'):
        lnum = error['start']['line']
        lcol = error['start']['col'] + 1
    vim.command("let l:tmp = {'bufnr':%d,'lnum':%d,'col':%d,'vcol':0,'nr':%d,'pattern':'','text':'%s','type':'%s','valid':1}" %
        (bufnr, lnum, lcol, nr, error['message'].replace("'", "''").replace("\n", " "), ty))
    nr = nr + 1
    vim.command("call add(%s, l:tmp)" % vimvar)

def vim_find_list(vimvar):
  pkgs = command_find_list()
  vim.command("let %s = []" % vimvar)
  for pkg in pkgs:
    vim.command("call add(%s, '%s')" % (vimvar, pkg))

def vim_type(expr=None,is_approx=False):
  to_line, to_col = vim.current.window.cursor
  cmd_at = ["at", {'line':to_line,'col':to_col}]
  sync_buffer_to(to_line,to_col)
  cmd_expr = ["expression", expr] if expr else []
  try:
    cmd = ["type"] + cmd_expr + cmd_at
    ty = send_command(*cmd)
    if isinstance(ty,dict):
      if "type" in ty: ty = ty['type']
      else: ty = str(ty)
    if is_approx: sys.stdout.write("(approx) ")
    if expr: print(expr + " : " + ty)
    else: print(ty)
  except MerlinExc as e:
    if expr:
      vim_type(expr=None,is_approx=True)
    else:
      try_print_error(e)

# expr used as fallback in case type_enclosing fail
def vim_type_enclosing(vimvar,expr=None):
  global enclosing_types
  global current_enclosing
  enclosing_types = [] # reset
  current_enclosing = -1
  to_line, to_col = vim.current.window.cursor
  sync_buffer()
  try:
    result = send_command("type", "enclosing", {'line':to_line,'col':to_col})
    enclosing_types = result[1]
    if enclosing_types == []:
      vim_type(expr=expr, is_approx=True)
    else:
      vim_next_enclosing(vimvar)
  except MerlinExc:
    vim_type(expr=expr, is_approx=True)

def easy_matcher(start, stop):
  startl = ""
  startc = ""
  if start['line'] > 0:
    startl = "\%>{0}l".format(start['line'] - 1)
  if start['col'] > 0:
    startc = "\%>{0}c".format(start['col'])
  return '{0}{1}\%<{2}l\%<{3}c'.format(startl, startc, stop['line'] + 1, stop['col'] + 1)

def hard_matcher(start, stop):
  first_start = {'line' : start['line'], 'col' : start['col']}
  first_stop =  {'line' : start['line'], 'col' : 4242}
  first_line = easy_matcher(first_start, first_stop)
  mid_start = {'line' : start['line']+1, 'col' : 0}
  mid_stop =  {'line' : stop['line']-1 , 'col' : 4242}
  middle = easy_matcher(mid_start, mid_stop)
  last_start = {'line' : stop['line'], 'col' : 0}
  last_stop =  {'line' : stop['line'], 'col' : stop['col']}
  last_line = easy_matcher(last_start, last_stop)
  return "{0}\|{1}\|{2}".format(first_line, middle, last_line)

def make_matcher(start, stop):
  if start['line'] == stop['line']:
    return easy_matcher(start, stop)
  else:
    return hard_matcher(start, stop)

def vim_next_enclosing(vimvar):
  if enclosing_types != []:
    global current_enclosing
    if current_enclosing < len(enclosing_types):
        current_enclosing += 1
    if current_enclosing < len(enclosing_types):
      tmp = enclosing_types[current_enclosing]
      matcher = make_matcher(tmp['start'], tmp['end'])
      vim.command("let {0} = matchadd('EnclosingExpr', '{1}')".format(vimvar, matcher))
      print(tmp['type'])

def vim_prev_enclosing(vimvar):
  if enclosing_types != []:
    global current_enclosing
    if current_enclosing >= 0:
      current_enclosing -= 1
    if current_enclosing >= 0:
      tmp = enclosing_types[current_enclosing]
      matcher = make_matcher(tmp['start'], tmp['end'])
      vim.command("let {0} = matchadd('EnclosingExpr', '{1}')".format(vimvar, matcher))
      print(tmp['type'])

# Resubmit current buffer
def vim_reload_buffer():
  sync_buffer()

# Reload changed cmi files then retype all definitions
def vim_is_loaded():
  return (mainpipe != None)

def vim_reload():
  command_reload()

# Spawn a fresh new process
def vim_restart():
  restart()

def vim_which(name,ext):
  if ext:
    name = name + "." + ext
  return command_which_file(name)

def vim_which_ext(ext,vimvar):
  files = command_which_with_ext(ext)
  vim.command("let %s = []" % vimvar)
  for f in sorted(set(files)):
    vim.command("call add(%s, '%s')" % (vimvar, f))

def vim_use(*args):
  catch_and_print(lambda: command_find_use(*args))

def vim_clear_flags():
  global flags
  flags = []
  restart()

def vim_add_flags(*args):
  flags.extend(args)
  restart()

def vim_selectphrase(l1,c1,l2,c2):
  vl1 = int(vim.eval(l1))
  vc1 = int(vim.eval(c1))
  vl2 = int(vim.eval(l2))
  vc2 = int(vim.eval(c2))
  sync_buffer_to(vl2,vc2)
  command_seek_exact(vl2,vc2)
  loc2 = send_command("boundary")
  if vl2 != vl1 or vc2 != vc1:
    command_seek_exact(vl1,vc1)
    loc1 = send_command("boundary")
  else:
    loc1 = None

  if loc2 == None:
    return

  vl1 = loc2[0]['line']
  vc1 = loc2[0]['col']
  vl2 = loc2[1]['line']
  vc2 = loc2[1]['col']
  if loc1 != None:
    vl1 = min(loc1[0]['line'], vl1)
    vc1 = min(loc1[0]['col'], vc1)
    vl2 = max(loc1[1]['line'], vl2)
    vc2 = max(loc1[1]['col'], vc2)
  for (var,val) in [(l1,vl1),(l2,vl2),(c1,vc1),(c2,vc2)]:
    vim.command("let %s = %d" % (var,val))

def load_project(directory,maxdepth=3):
  fname = os.path.join(directory,".merlin") 
  if os.path.exists(fname):
    #with open(fname,"r") as f:
    #  for line in f:
    #    split = line.split(None,1)
    #    if split != []:
    #      command = split[0]
    #      tail = split[1]
    #      if command and command[0] == '#':
    #        continue
    #      if tail != "":
    #        tail = os.path.join(directory,tail)
    #      if command == "S":
    #        send_command("path","add","source",tail.strip())
    #      elif command == "B":
    #        send_command("path","add","build",tail.strip())
    #      elif command == "PKG":
    #        catch_and_print(lambda: command_find_use(*split[1].split()))
    send_command("project","load",fname)
    vim.command('let b:dotmerlin="%s"' % fname)
    command_reset()
  elif maxdepth > 0:
    (head, tail) = os.path.split(directory)
    if head != "":
      load_project(head,maxdepth - 1)

# vim:tabstop=2:shiftwidth=2:softtabstop=2:set expandtab
