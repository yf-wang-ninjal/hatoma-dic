# frozen-string-literal: true

require 'csv'
require 'rexml/document'

HATOMA_ID = 'HATOMA'
HATOMA_LANG = 'rys-x-hatoma'
JA_LANG = 'ja'
TAGS = {
  exp: /\{Exp_(?<exp_n>[\d-]+)\}/,
  pos: /\{PoS_\d+\}/,
  mn: /\{Mn_(?<mn_n>\d+)\}/,
  sg: /\{Sg_(?<sg_n>\d+)\}/,
  rel: /\{Rel_(?<rel_n>\d+)\}/,
  ref: /\{Ref_(?<ref_type>[A-Za-z]+)_(?<ref_n>\d+)\}/,
  eos: '{EOS}',
  eosx: '{EOS!}',
  sqbr: %r|\{SqBr\}(?<sqbr_txt>[^{}]+)\{/SqBr\}|, # ruby で使用するためそれより前に処理
  ruby: /\\ruby(?<ruby_opt>\[[^\[\]]+\])?\{(?<ruby_base>[^{}]+)\}\{(?<ruby_txt>[^{}]+)\}/,
  break: /\{Break\}(?<break_txt>[^{}]+)\{Break\}/,
  # list のあとに句読点など（？）を挟んですぐに list が続くものは箇条の参照なので除外
  list: /(?<list>\((?:x{0,3}(?:ix|iv|v?i{0,3})|[イロ])\))(?<invalid_cond>[、~]\g<list>)?/
}.freeze
CATS = {
  # パターン => [type, 正規化, 先頭以外でも適用]
  '動' => [:domain, '動', true],
  '植' => [:domain, '植'],
  '地' => [:domain, '地'],
  '数' => [:domain, '数'],
  '海底地名' => [:domain, '海底地名'],
  '人' => [:domain, '人'],
  '動物' => [:domain, '動'],
  '固' => [:domain, '固'],
  '地名' => [:domain, '地'],
  '幼' => [:socioCultural, '幼'],
  '人名' => [:domain, '人'],
  '数詞' => [:domain, '数'],
  '擬音語' => [:meaningType, '擬音語'],
  '幼児語' => [:domain, '幼', true],
  '固有' => [:domain, '地'],
  '昆虫' => [:domain, '動'],
  '昆' => [:domain, '動'],
  '謙譲語' => [:socioCultural, '謙譲語', true],
  '擬態語' => [:domain, '擬態語'],
  '植物' => [:domain, '植'],
  '屋' => [:domain, '屋'],
}.freeze
CAT_EXP = /#{CATS.keys.map { |k| "(?<#{k}>\\(#{k}\\))" }.join('|')}/
CATS_MID = CATS.select { |_, v| v[2] }

def to_text(str_or_elem, strip=false)
  str_or_elem.is_a?(String) ? REXML::Text.new(strip ? str_or_elem.strip : str_or_elem) : str_or_elem
end

def gen_gramgrp(parent, pos)
  pos_gram = REXML::Element.new 'gramGrp'
  pos_name = REXML::Element.new 'gram', pos_gram
  pos_name.add_attributes 'type' => 'pos'
  pos_name.text = pos
  parent.push pos_gram
end

def gen_ex(id, order_id, content, context)
  unless content.empty?
    cite = REXML::Element.new 'cit'
    cite.add_attributes 'type' => 'example', 'xml:id' => "#{HATOMA_ID}.#{id}", 'n' => order_id

    cnt, cxt = [content, context].map do |c|
      if c.empty?
        []
      else
        quote = REXML::Element.new 'quote'
        untag(c[0], id).each { |n| quote.push n }
        pron = REXML::Element.new 'pron'
        pron.add_attributes 'notation' => 'IPA'
        untag(c[1], id).each { |n| pron.push n }
        trans = REXML::Element.new 'cit'
        trans.add_attributes 'type' => 'translation', 'xml:lang' => JA_LANG
        tr_quote = REXML::Element.new 'quote', trans
        untag(c[2], id).each { |n| tr_quote.push n }
        extra = c[3] ? untag(c[3], id) : nil
        [quote, pron, trans, extra]
      end
    end

    unless cxt.empty?
      prev_note = REXML::Element.new 'note'
      prev_cite = REXML::Element.new cite, prev_note
      cxt[0..2].each { |x| prev_cite.push x }
      untag(cxt[3], id).each { |n| prev_note.push n }
      cite.push prev_note
    end
    cnt[0..2].each { |n| cite.push n }
    if cnt[3]
      after_note = REXML::Element.new 'note'
      untag(cnt[3], id).each { |n| after_note.push n }
      cite.push after_note
    end
  end

  [cite, [], []] # 引数の上書き用に空の配列を二つ返す
end

# build_unit() 用の定数
EXPID_MULT = 100_000 # MnID の倍数（十分大きな数）
MNID_EXP_MULT = 1_000_000 # Exp を持つ MnID の倍数（EXPID_MULT よりも十分大きな数）
# rubocop:disable Metrics/*
def build_unit(parent, lines, gram: false)
  head = lines.first
  # {Exp_*} 持ちと MnID > 0 は共起しない（例外あり）
  # ↓ MnID の子である Exp の収納用
  subexps = {}
  lines
    .group_by do |gr|
      has_expid = gr['Description']&.index(TAGS[:exp])&.zero?
      if gr['MnID'].to_i.positive? && has_expid
        gr['MnID'].to_i * MNID_EXP_MULT + get_expid(gr).tr('-', '.').to_f
      else
        gr['MnID'].to_i + (has_expid ? get_expid(gr).tr('-', '.').to_f + EXPID_MULT : 0)
      end
    end.sort.each do |(grid, group)|
    is_exp = grid >= EXPID_MULT
    mn_exp = grid >= MNID_EXP_MULT ? "#{grid.div MNID_EXP_MULT}." : ''
    elid = "#{head['WdID']}.#{head['PoSID']}.#{mn_exp}#{is_exp ? "EXP#{get_expid group.first}" : grid}"
    elem = REXML::Element.new is_exp ? 'note' : 'sense'
    elem.add_attributes 'xml:id' => "#{HATOMA_ID}.#{elid}"
    # grid < EXPID_MULT は Mn
    gen_gramgrp elem, group.first['PoS'] if gram && grid < EXPID_MULT

    group.sort_by { |l| l['Order'].to_f }.each do |unit|
      uorder = unit['Order'].to_f * 10 # Order 小数化に伴い、出力上の ID を 10 倍する
      if is_exp
        substructure(unit['Description'], elid).compact.each { |u| elem.push to_text(u, true) }
        att_n = elem.attribute 'n'
        elem.add_attribute 'n', att_n ? "#{att_n.value} #{uorder}" : uorder
      else
        def_elem = REXML::Element.new 'def'
        def_elem.add_attributes 'xml:lang' => JA_LANG, 'n' => uorder
        substructure(unit['Description'], elid).compact.each { |u| def_elem.push to_text(u, true) }
        elem.push def_elem
      end

      # https://stackoverflow.com/a/6807722
      unit['Description']&.to_enum(:scan, CAT_EXP)&.map { Regexp.last_match }&.each do |c|
        cats = c.begin(0) <= 0 ? CATS : CATS_MID
        cats.any? do |k, v|
          ck = c.named_captures[k]
          if ck
            usg = REXML::Element.new 'usg'
            usg.add_attributes 'type' => v[0]
            usg.text = v[1]
            gram ? (elem.insert_after 'gramGrp', usg) : (elem.unshift usg)
          end
          ck
        end
      end

      skip = 0
      skip_this = false
      store = []
      prev = []
      prev_note = []
      exs = unit.fields(10..-1).compact
      exs.each.with_index do |f, fi|
        # 歌が本文に混ざりこんでいることがあるので例文にできない
        # # TODO: 修正版形式では歌が例文スロットに入るのでここで分岐させる
        # f.start_with?(TAGS[:sg]) do |m|
        #   # TODO
        #   skip_this = true
        # end
        f.match(TAGS[:break]) do |m|
          prev = store + [m[:break_txt]]
          skip_this = true
        end
        if skip_this
          skip += 1
          skip_this = false
          next
        end

        exq, exr = (fi - skip).divmod(3)

        case exr
        when 0
          # この段階で前の例文を親に収納するが、この時点で exq は収納される例文の次の index を示している。したがって実質的に例文番号が 1 始まりで収納される
          cite, store, prev_note = gen_ex "#{elid}.#{exq}", uorder, store, prev_note
          elem.push cite if cite
          store << f
          prev_note = prev unless prev.empty?
        when 1
          store << f
        when 2
          f1, f2 = f.strip.split /(?<=\)。)/, 2
          store << f1
          store << f2 unless f2.nil? || f2.empty?
        end
      end

      cite, = gen_ex "#{elid}.#{(exs.size - skip).div 3}", uorder, store, prev_note
      elem.push cite if cite
    end

    if grid > MNID_EXP_MULT
      parent_mn = grid.div MNID_EXP_MULT
      subexps[parent_mn] ||= []
      subexps[parent_mn].push elem
    else
      parent.push elem
    end
  end

  return if subexps.empty?

  subexps.each do |mn, subs|
    mn_el = REXML::XPath.first parent, "./sense[@xml:id='#{HATOMA_ID}.#{head['WdID']}.#{head['PoSID']}.#{mn}']"
    subs.each { |s| mn_el.push s }
  end
end
# rubocop:enable Metrics/*

def substructure(text, id)
  if !text
    [] # TODO: 空のテキストはあってよい？
  # 歌の場合
  elsif text.match? TAGS[:sg]
    # 歌統一後の形式
    sections = text.split %r|(\{Sg_\d+\}.+?\{/End\})| # 終端は必ず大文字のEnd
    sections.flat_map.with_index do |s, i|
      if i.odd?
        song_container = REXML::Element.new 'seg'
        song_container.add_attributes 'type' => 'songs'
        # 各要素が [開始タグ, 内容] の配列となる
        s.delete_suffix('{/End}').split(/(\{Sg_\d+\}|\{Title\}|\{Bibl\})/)[1..].each_slice(2) do |(title, content)|
          case title
          when TAGS[:sg]
            num = Regexp.last_match[:sg_n]
            my_id = "#{HATOMA_ID}.#{id}.SG#{num}"
            song = REXML::Element.new 'cit', song_container
            song.add_attributes 'type' => 'example', 'xml:id' => my_id
            uta = REXML::Element.new 'usg', song
            uta.add_attributes 'type' => 'textType'
            uta.text = '歌'
            begin
              perf, quote, trs = content.match(%r|\A\s*(?:{Performer}(.+){/Performer})?((?:\([五六七]\))?[^(]+)\s*(\(([^)]+)\))?|)[1..3] # FIXME: Order: 5266 仮対策
            rescue NoMethodError
              p "#{id} -- #{content}"
            end

            if perf
              pf = REXML::Element.new 'seg', song
              pf.add_attributes 'type' => 'performer'
              untag(perf, my_id).each { |t| pf << to_text(t, true) }
            end
            qt = REXML::Element.new 'quote', song
            untag(quote, my_id).each { |t| qt << to_text(t, true) }
            tr = REXML::Element.new 'cit', song
            tr.add_attributes 'type' => 'translation', 'xml:lang' => JA_LANG
            tr_q = REXML::Element.new 'quote', tr
            untag(trs, my_id).each { |t| tr_q << to_text(t, true) }
          when '{Title}'
            title = REXML::Element.new 'title', song_container
            begin
              b = content.match(%r|\A\s*(.+)\s*{/Title}|)[1]
            rescue NoMethodError
              p "#{id} -- #{content}"
            end
            untag(b, my_id).each { |t| title << to_text(t, true) }
          when '{Bibl}'
            bibl = REXML::Element.new 'bibl', song_container
            begin
              b = content.match(%r|\A\s*(.+)\s*{/Bibl}|)[1]
            rescue NoMethodError
              p "#{id} -- #{content}"
            end
            untag(b, my_id).each { |t| bibl << to_text(t, true) }
          end
        end

        song_container
      else
        untag s, id
      end
    end
  # 箇条書きの場合
  elsif text.match? TAGS[:list]
    segs = text.split %r<(\((?:x{0,3}(?:ix|iv|v?i{0,3})|[イロ])\).+?\{/end\})> # 終端は必ず小文字のend
    segs.flat_map.with_index do |s, i|
      if i.odd?
        # TODO: 現行の Lex-0 では <def> に <list> を直接入れられない
        container = REXML::Element.new 'hi'
        container.add_attributes 'type' => 'list'
        list = REXML::Element.new 'list', container
        s.delete_suffix('{/end}').split(TAGS[:list])[1..].each_slice(2) do |(title, content)|
          item = REXML::Element.new 'item', list
          item.add_attributes 'n' => title.delete_prefix('(').delete_suffix(')')
          untag(content, id).each { |t| item << to_text(t, true) }
        end

        container
      else
        # TODO
        untag s, id
      end
    end
  else
    untag text, id
  end
end

def untag(text, id)
  # 一度テキストをXML用にエスケープ
  txt = +(REXML::Text.normalize text)

  TAGS.each do |t, rx|
    txt.gsub!(rx) do |_|
      m = Regexp.last_match
      case t
      when :rel
        # TODO
      when :ref
        ref = REXML::Element.new 'ref'
        # TODO: 親要素のIDの末尾を除いたものからの相対アドレスでOK？
        # TODO: すべて type=sense？
        ref.add_attributes 'type' => 'sense', 'target' => "##{id.rpartition('.').first}.#{m[:ref_type] == 'Exp' ? 'EXP' : ''}#{m[:ref_n]}"
        ref.to_s
      when :eos
        '。'
      when :eosx
        '!'
      when :sqbr
        "[#{m[:sqbr_txt]}]"
      when :ruby
        if m[:ruby_opt] == '[g]'
          ruby(m[:ruby_base], m[:ruby_txt]).to_s
        else
          m[:ruby_base].split('').zip(m[:ruby_txt].split('|')).map { |b, t| ruby(b, t).to_s }.join
        end
      when :break
        m[:break_txt]
      else
        ''
      end
    end
  end

  # 直列化したXMLは REXML::Document として読み込ませることが必要？
  REXML::Document.new("<root>#{txt}</root>").root.children
end

def get_expid(row)
  row['Description'][TAGS[:exp], 'exp_n']
end

def ruby(base, text)
  ruby = REXML::Element.new 'ruby'
  rb = REXML::Element.new 'rb', ruby
  rb.text = base
  rt = REXML::Element.new 'rt', ruby
  rt.text = text

  ruby
end

dict = ARGV[0]
tei = REXML::Document.new IO.read "#{__dir__}/template.xml", mode: 'r:utf-8'
body = REXML::XPath.first tei, '//text/body'

matrix = CSV.read dict, col_sep: "\t", headers: true, liberal_parsing: true

matrix.chunk { |e| e['WdID'] }.each do |_, entries|
  next if entries.empty?

  head = entries.first

  # TODO: 辞書の頭文字見出しの行、要検討
  if head['WdID'].match? /^<title>/
    # heading = REXML::Element.new 'head'
    # heading.text = REXML::Document.new(head['WdID']).children.first.text
    # body.push heading
  else
    archentry = REXML::Element.new 'entry'
    archentry.add_attributes 'xml:id' => "#{HATOMA_ID}.#{head['WdID']}", 'xml:lang' => HATOMA_LANG

    form = REXML::Element.new 'form', archentry
    form.add_attributes 'type' => 'lemma'
    orth = REXML::Element.new 'orth', form
    orth.text = head['Wd']
    accent = REXML::Element.new 'pron', form
    accent.add_attributes 'notation' => 'accent'
    accent.text = head['Wd2']
    ipa = REXML::Element.new 'pron', form
    ipa.add_attributes 'notation' => 'IPA'
    ipa.text = head['WdIPA']
    # TODO: <media> は Lex-0 未対応
    audio = REXML::Element.new 'media', form
    audio.add_attributes 'mimeType' => 'audio/wav', 'url' => head['SoundFile'] || '#'

    pos_map = entries.map { |l| l['PoSID'] }.uniq

    if pos_map.size > 1
      entries.group_by { |l| l['PoSID'] }.each do |pid, pgroup|
        pos_entry = REXML::Element.new 'entry'
        pos_entry.add_attributes 'xml:id' => "#{HATOMA_ID}.#{head['WdID']}.#{pid}", 'xml:lang' => HATOMA_LANG, 'type' => 'homonymicEntry'

        gen_gramgrp pos_entry, pgroup.first['PoS']

        build_unit pos_entry, pgroup
        archentry.push pos_entry
      end
    else
      build_unit archentry, entries, gram: true
    end
    # TODO

    body.push archentry
  end
end

File.open(ARGV[1], 'w:utf-8') do |out|
  tei.write out, 2
end
