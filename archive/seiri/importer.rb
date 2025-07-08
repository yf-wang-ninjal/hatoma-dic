require 'sqlite3'
require 'csv'

HMAP = {
  'WdID' => :WdID,
  'PoSID' => :PoSID,
  'MnID' => :MnID,
  'Order' => :col_Order,
  'SoundFile' => :SoundFile,
  'Wd' => :Wd,
  'Wd2' => :Wd2,
  'WdIPA' => :WdIPA,
  'PoS' => :PoS,
  'Description' => :Description,
}

XMAP = {
  'WdID' => :WdID,
  'Wd' => :Wd,
  'SID' => :SID,
  '音声ファイル' => :SoundFile,
  'Ex' => :Ex,
  'IPA' => :IPA,
  'Trs' => :Trs,
}

HXMAP = %i(Ex IPA Trs)

def fmt(n)
  '%06d' % n
end

headwords = []
examples = []
head_exs = []
reports = []

CSV.foreach("20201030_hatoma_meaning_order.txt", col_sep: "\t", headers: true, liberal_parsing: true, skip_lines: /^<title>/).with_index(1) do |row, lno|
  # p row;p row.headers;row.each {|h,f| print "#{h}: #{f} "};break # debug
  hw = {}
  ex = []
  start = nil
  ended = false
  row.each.with_index(0) do |(header, field), i|
    if HMAP[header]
      hw[HMAP[header]] = field
    elsif header.nil?
      if field
        if ended
          reports.push "H#{fmt lno}: #{field} in col #{i} after end"
          next
        end
        start = i unless start
        ex.push({HXMAP[0] => row[i], HXMAP[1] => row[i+1], HXMAP[2] => row[i+2]}) if (i - start) % 3 == 0
      else
        ended = true
      end
    else
      reports.push "H#{fmt lno}: #{header} -> #{field} in col #{i}"
    end
  end

  headwords.push hw
  ex.each.with_index(1) do |x, xi|
    head_exs.push x.merge hw.slice(:WdID, :PoSID, :MnID, :col_Order, :Wd, :Wd2), {exid: xi}
  end
end

CSV.foreach("Hatoma_example_20220921.txt", col_sep: "\t", headers: true, liberal_parsing: true).with_index(1) do |row, lno|
  ex = {}
  unless row['SID']
    reports.push "X#{fmt lno}: Empty SID! #{row.to_hash.inspect}"
    next
  end

  row.each.with_index(0) do |(header, field), i|
    if XMAP[header]
      ex[XMAP[header]] = field
    else
      reports.push "X#{fmt lno}: #{header} -> #{field} in col #{i}"
    end
  end
  examples.push ex
end

open("reports.txt", 'w:UTF-8') do |report|
  reports.each { |r| report.puts r }
  examples.each { |e|
    next unless e[:SID] # 空のSIDはすでに上で対処済み

    if e[:IPA] !~ /\A\[/
      report.puts "X SID #{e[:SID]}: IPA #{e[:IPA]} ?"
    elsif e[:Trs] !~ /\A\(/
      report.puts "X SID #{e[:SID]}: Trs #{e[:IPA]} ?"
    end
  }
end

begin
  db = SQLite3::Database.open "hatoma_seiri.db"

  db.transaction
  headwords.each do |w|
    db.execute "INSERT INTO headwords (#{w.keys.join ','}) VALUES (#{(['?'] * w.keys.size).join ','})", w.values
  end
  db.commit

  db.transaction
  examples.each do |x|
    db.execute "INSERT INTO examples (#{x.keys.join ','}) VALUES (#{(['?'] * x.keys.size).join ','})", x.values
  end
  db.commit

  db.transaction
  head_exs.each do |hx|
    db.execute "INSERT INTO headword_exs (#{hx.keys.join ','}) VALUES (#{(['?'] * hx.keys.size).join ','})", hx.values
  end
  db.commit
  
rescue SQLite3::Exception => e
  puts "Exception occurred"
  puts e
ensure
  db.close if db
end