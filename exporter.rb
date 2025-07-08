# frozen-string-literal: true

require 'csv'
require 'rexml/document'

HATOMA_ID = 'HATOMA'
XML_LB = /[\r\n]+\s+/
ACCENT = /[⸢⸣]/

dic_file = ARGV[0]
exs_file = ARGV[1]
output_file = ARGV[2]

examples = []
indices = {
  dic_wd: {},
  dic_ex: {},
  dic_ex_fz: {},
  dic_pr_fz: {},
  ex_sid: {},
  ex_file: {},
  ex_soundx_ex: {},
  ex_soundx_pr: {},
  ex_soundx_ex_fz: {},
  ex_soundx_pr_fz: {}
}

CSV.foreach(exs_file, col_sep: "\t", headers: true, liberal_parsing: true).with_index(2) do |row, lno|
  $stdout.puts "EXS indexing: #{lno}" if (lno % 1000).zero?
  if row['SID'] || row['Ex']
    ex_fuzzy = row['Ex']&.gsub ACCENT, ''
    ipa_fuzzy = row['IPA']&.gsub ACCENT, ''
    examples.push row.to_hash.merge({ 'exrow' => lno, 'Ex2' => ex_fuzzy, 'IPA2' => ipa_fuzzy })
    indices[:ex_sid][row['SID']] ||= Set.new
    indices[:ex_sid][row['SID']].add lno
    if row['音声ファイル'].empty? || row['音声ファイル'] == 'x'
      [[row['Ex'], :ex_soundx_ex], [row['IPA'], :ex_soundx_pr], [ex_fuzzy, :ex_soundx_ex_fz], [ipa_fuzzy, :ex_soundx_pr_fz]].each do |(v, k)|
        next unless v
        indices[k][v] ||= Set.new
        indices[k][v].add lno
      end
    else
      indices[:ex_file][row['音声ファイル']] ||= Set.new
      indices[:ex_file][row['音声ファイル']].add lno
    end
  end
end
$stdout.puts 'EXS indexed'

ex_groups = examples.group_by { |x| x['WdID'] }.transform_values { |v| v.group_by { |vv| vv['Ex'] } }
$stdout.puts 'EXS grouped'

dictionary = REXML::Document.new IO.read dic_file, mode: 'r:utf-8'
exs_by_entry = {}
REXML::XPath.each(dictionary, '/TEI/text/body/entry').with_index(1) do |entry, eno|
  $stdout.puts "DIC indexing: #{eno}" if (eno % 1000).zero?
  id = entry.attribute('xml:id').value.delete_prefix "#{HATOMA_ID}."
  wd2 = REXML::XPath.first(entry, './form[@type="lemma"]/pron[@notation="accent"]').get_text.value
  REXML::XPath.each(entry, './/cit[@type="example" and not(normalize-space(./usg/text()) = "歌")]') do |ex|
    exs_by_entry[id] ||= []
    xid = ex.attribute('xml:id').to_s.delete_prefix "#{HATOMA_ID}.#{id}."
    # 中間の複数スペースが消える恐れがあるため normalize-space はしない
    orig = REXML::XPath.first(ex, './quote')&.get_text&.value&.strip&.gsub XML_LB, ' '
    pron = REXML::XPath.first(ex, './pron')&.get_text&.value&.strip&.gsub XML_LB, ' '
    trans = REXML::XPath.first(ex, './cit[@type="translation"]/quote')&.children&.map { |ch|
      ch.to_s.strip.gsub XML_LB, ' '
    }&.join
    orig_fuzzy = orig&.gsub ACCENT, ''
    pron_fuzzy = pron&.gsub ACCENT, ''
    exs_by_entry[id].push({ 'ID' => id, 'ExID' => xid, 'Order' => ex.attribute('n'), 'Ex' => orig, 'IPA' => pron, 'Trs' => trans, 'Ex2' => orig_fuzzy, 'IPA2' => pron_fuzzy })

    [[wd2, :dic_wd], [orig, :dic_ex], [orig_fuzzy, :dic_ex_fz], [pron_fuzzy, :dic_pr_fz]].each do |(v, k)|
      next unless v
      indices[k][v] ||= Set.new
      indices[k][v].add [id, xid]
    end
  end
  # TODO?
end
$stdout.puts 'DIC indexed'

alignment = []
build_hash = lambda { |x|
  {
    ex_rowid: x['exrow'],
    ex_wdid: x['WdID'],
    ex_wd: x['Wd'],
    ex_sid: x['SID'],
    ex_file: x['音声ファイル'],
    ex_ex: x['Ex'],
    ex_ipa: x['IPA'],
    ex_trs: x['Trs'],
    dic_id: nil,
    dic_xid: nil,
    dic_xorder: nil,
    dic_ex: nil,
    dic_ipa: nil,
    dic_trs: nil,
    dup_on_sid: indices[:ex_sid][x['SID']],
    dup_on_file: indices[:ex_file][x['音声ファイル']],
    flag_wdid: false,
    flag_ipa: false,
    flag_trs: false,
    no_ex: x['Ex']&.empty?,
    no_ipa: x['IPA']&.empty?,
    no_trs: x['Trs']&.empty?,
    possible_dic_by_ex: indices[:dic_ex_fz][x['Ex2']],
    possible_dic_by_pr: indices[:dic_pr_fz][x['IPA2']],
    possible_ex_by_ex: nil,
    possible_ex_by_pr: nil,
    possible_ex_by_ex_fz: nil,
    possible_ex_by_pr_fz: nil
    # TODO?
  }
}
examples.each do |x|
  next if (x['音声ファイル'].empty? || x['音声ファイル'] == 'x') && ex_groups[x['WdID']][x['Ex']].size > 1
  $stdout.puts "matching: exrow #{x['exrow']}" if (x['exrow'] % 1000).zero?

  al = build_hash[x]
  # 同じ `WdID` を持ち、`Ex` が同じもののうち残っている先頭の語彙例文と対応
  if (match = exs_by_entry[x['WdID']]&.find { |ex| ex['Ex'] == x['Ex'] && !ex[:used] })
    match[:used] = x['exrow']
    al.update(
      dic_id: x['WdID'],
      dic_xid: match['ExID'],
      dic_xorder: match['Order'],
      dic_ex: match['Ex'],
      dic_ipa: match['IPA'],
      dic_trs: match['Trs'],
      flag_ipa: x['IPA'] != match['IPA'],
      flag_trs: x['Trs'] != match['Trs']
    )
  # `Wd` が語彙例文 `Wd2` に一致するもので `Ex` が同じもののうち残っている先頭の語彙例文と対応
  elsif (match = indices[:dic_wd][x['Wd']]&.flat_map { |(id, xid)| exs_by_entry[id].select { |i| i['ExID'] == xid && !ex[:used] && i['Ex'] == x['Ex'] } }&.min_by { |i| "#{i['ID']}.#{i['ExID']}" })
    match[:used] = x['exrow']
    al.update(
      dic_id: match['ID'],
      dic_xid: match['ExID'],
      dic_xorder: match['Order'],
      dic_ex: match['Ex'],
      dic_ipa: match['IPA'],
      dic_trs: match['Trs'],
      flag_wdid: true,
      flag_ipa: x['IPA'] != match['IPA'],
      flag_trs: x['Trs'] != match['Trs']
    )
  end

  alignment.push al
end
$stdout.puts 'matching finished'

# 未対応の語彙例文を列挙（はじいた `x` の音声と突き合わせ？）
$stdout.puts "unused DIC examples: #{exs_by_entry.values.map { |v| v.reject { |x| x[:used]}.size }.sum}"
exs_by_entry.each_value do |exs|
  exs&.reject { |x| x[:used] }&.each do |unused|
    alignment.push(
      dic_id: unused['ID'],
      dic_xid: unused['ExID'],
      dic_xorder: unused['Order'],
      dic_ex: unused['Ex'],
      dic_ipa: unused['IPA'],
      dic_trs: unused['Trs'],
      possible_ex_by_ex: indices[:ex_soundx_ex][unused['Ex']],
      possible_ex_by_pr: indices[:ex_soundx_pr][unused['IPA']],
      possible_ex_by_ex_fz: indices[:ex_soundx_ex_fz][unused['Ex2']],
      possible_ex_by_pr_fz: indices[:ex_soundx_pr_fz][unused['IPA2']]
    )
  end
end
$stdout.puts 'matching unused finished'
$stdout.puts "results: #{alignment.size} rows"

File.open(output_file, 'w:utf-8') do |out|
  header = {
    ex_rowid: '例文行番号',
    ex_wdid: '例文WdID',
    ex_wd: '例文Wd',
    ex_sid: '例文SID',
    ex_file: '例文音声ファイル',
    ex_ex: '例文Ex',
    ex_ipa: '例文IPA',
    ex_trs: '例文Trs',
    dic_id: '語彙WdID',
    dic_xid: '語彙例文ID',
    dic_xorder: '語彙Order',
    dic_ex: '語彙例文原文',
    dic_ipa: '語彙例文IPA',
    dic_trs: '語彙例文訳',
    dup_on_sid: '同一SID（行番号）',
    dup_on_file: '同一音声ファイル（行番号）',
    flag_wdid: 'WdID相違',
    flag_ipa: 'IPA相違',
    flag_trs: '訳相違',
    no_ex: '例文Exなし',
    no_ipa: '例文IPAなし',
    no_trs: '例文Trsなし',
    possible_dic_by_ex: 'Exがほぼ一致する語彙例文',
    possible_dic_by_pr: 'IPAがほぼ一致する語彙例文',
    possible_ex_by_ex: 'Exが一致する未対応例文',
    possible_ex_by_pr: 'IPAが一致する未対応例文',
    possible_ex_by_ex_fz: 'Exがほぼ一致する未対応例文',
    possible_ex_by_pr_fz: 'IPAがほぼ一致する未対応例文'
  }
  out.puts header.values.join "\t"

  alignment.each.with_index(1) do |a, ano|
    $stdout.puts "generating: #{ano}" if (ano % 1000).zero?
    mapped = header.keys.map do |k|
      case k
      when :dup_on_sid, :dup_on_file, :possible_ex_by_ex, :possible_ex_by_ex_fz, :possible_ex_by_pr, :possible_ex_by_pr_fz
        a[k]&.join ','
      when :possible_dic_by_ex, :possible_dic_by_pr
        a[k]&.map { |vv| vv&.join '.' }&.join ','
      when :flag_wdid, :flag_ipa, :flag_trs, :no_ex, :no_ipa, :no_trs
        a[k] ? 1 : 0
      else
        a[k].to_s
      end
    end
    out.puts mapped&.join("\t")
  end
end
$stdout.puts 'generated'
