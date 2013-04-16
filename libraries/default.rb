#
# Cookbook Name:: postgresql
# Library:: default
# Author:: David Crane (<davidc@donorschoose.org>)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include Chef::Mixin::ShellOut

module Opscode
  module PostgresqlHelpers

#######
# Function to truncate value to 4 significant bits, render human readable.
# Used in recipes/config_initdb.rb to set this attribute:
#
# The memory settings (shared_buffers, effective_cache_size, work_mem,
# maintenance_work_mem and wal_buffers) will be rounded down to keep
# the 4 most significant bits, so that SHOW will be likely to use a
# larger divisor. The output is actually a human readable string that
# ends with "GB", "MB" or "kB" if over 1023, exactly what Postgresql
# will expect in a postgresql.conf setting. The output may be up to
# 6.25% less than the original value because of the rounding.
def binaryround(value)

    # Keep a multiplier which grows through powers of 1
    multiplier = 1

    # Truncate value to 4 most significant bits
    while value >= 16
        value = (value / 2).floor
        multiplier = multiplier * 2
    end

    # Factor any remaining powers of 2 into the multiplier
    while value == 2*((value / 2).floor)
        value = (value / 2).floor
        multiplier = multiplier * 2
    end

    # Factor enough powers of 2 back into the value to
    # leave the multiplier as a power of 1024 that can
    # be represented as units of "GB", "MB" or "kB".
    if multiplier >= 1024*1024*1024
      while multiplier > 1024*1024*1024
        value = 2*value
        multiplier = (multiplier/2).floor
      end
      multiplier = 1
      units = "GB"

    elsif multiplier >= 1024*1024
      while multiplier > 1024*1024
        value = 2*value
        multiplier = (multiplier/2).floor
      end
      multiplier = 1
      units = "MB"

    elsif multiplier >= 1024
      while multiplier > 1024
        value = 2*value
        multiplier = (multiplier/2).floor
      end
      multiplier = 1
      units = "kB"

    else
      units = ""
    end

    # Now we can return a nice human readable string.
    return "#{multiplier * value}#{units}"
end

#######
# Locale Configuration

# Function to test the date order.
# Used in recipes/config_initdb.rb to set this attribute:
#    node.default['postgresql']['config']['datestyle']
def locale_date_order
    # Test locale conversion of mon=11, day=22, year=33
    testtime = DateTime.new(2033,11,22,0,0,0,"-00:00")
            #=> #<DateTime: 2033-11-22T00:00:00-0000 ...>

    # %x - Preferred representation for the date alone, no time
    res = testtime.strftime("%x")

    if res.nil?
       return 'mdy'
    end

    posM = res.index("11")
    posD = res.index("22")
    posY = res.index("33")

    if (posM.nil? || posD.nil? || posY.nil?)
        return 'mdy'
    elseif (posY < posM && posM < posD)
        return 'ymd'
    elseif (posD < posM)
        return 'dmy'
    else
        return 'mdy'
    end
end
  
#######
# Timezone Configuration
require 'find'

# Function to determine where the system stored shared timezone data.
# Used in recipes/config_initdb.rb to detemine where it should have
# select_default_timezone(tzdir) search.
def pg_TZDIR()
    # System time zone conversions are controlled by a timezone data file
    # identified through environment variables (TZ and TZDIR) and/or file
    # and directory naming conventions specific to the Linux distribution.
    # Each of these timezone names will have been loaded into the PostgreSQL
    # pg_timezone_names view by the package maintainer.
    #
    # Instead of using the timezone name configured as the system default,
    # the PostgreSQL server uses ones named in postgresql.conf settings
    # (timezone and log_timezone). The initdb utility does initialize those
    # settings to the timezone name that corresponds to the system default.
    #
    # The system's timezone name is actually a filename relative to the
    # shared zoneinfo directory. That is usually /usr/share/zoneinfo, but
    # it was /usr/lib/zoneinfo in older distributions and can be anywhere
    # if specified by the environment variable TZDIR. The tzset(3) manpage
    # seems to indicate the following precedence:
    tzdir = nil
    if ::File.directory?("/usr/lib/zoneinfo")
        tzdir = "/usr/lib/zoneinfo"
    else
        share_path = [ ENV['TZDIR'], "/usr/share/zoneinfo" ].compact.first
        if ::File.directory?(share_path)
            tzdir = share_path
        end
    end
    return tzdir
end

#######
# Function to support select_default_timezone(tzdir), which is
# used in recipes/config_initdb.rb.
def validate_zone(tzname)
    # PostgreSQL does not support leap seconds, so this function tests
    # the usual Linux tzname convention to avoid a misconfiguration.
    # Assume that the tzdata package maintainer has kept all timezone
    # data files with support for leap seconds is kept under the
    # so-named "right/" subdir of the shared zoneinfo directory.
    #
    # The original PostgreSQL initdb is not Unix-specific, so it did a
    # very complicated, thorough test in its pg_tz_acceptable() function
    # that I could not begin to understand how to do in ruby :).
    #
    # Testing the tzname is good enough, since a misconfiguration
    # will result in an immediate fatal error when the PostgreSQL
    # service is started, with pgstartup.log messages such as:
    # LOG:  time zone "right/US/Eastern" appears to use leap seconds
    # DETAIL:  PostgreSQL does not support leap seconds.

    if tzname.index("right/") == 0
        return false
    else
        return true
    end
end

# Function to support select_default_timezone(tzdir), which is
# used in recipes/config_initdb.rb.
def scan_available_timezones(tzdir)
    # There should be an /etc/localtime zoneinfo file that is a link to
    # (or a copy of) a timezone data file under tzdir, which should have
    # been installed under the "share" directory by the tzdata package.
    #
    # The initdb utility determines which shared timezone file is being
    # used as the system's default /etc/localtime. The timezone name is
    # the timezone file path relative to the tzdir.

    bestzonename = nil

    if (tzdir.nil?)
        Chef::Log.error("The zoneinfo directory not found (looked for /usr/share/zoneinfo and /usr/lib/zoneinfo)")
    elsif !::File.exists?("/etc/localtime")
        Chef::Log.error("The system zoneinfo file not found (looked for /etc/localtime)")
    elsif ::File.directory?("/etc/localtime")
        Chef::Log.error("The system zoneinfo file not found (/etc/localtime is a directory instead)")
    elsif ::File.symlink?("/etc/localtime")
        # PostgreSQL initdb doesn't use the symlink target, but this
        # certainly will make sense to any system administrator. A full
        # scan of the tzdir to find the shortest filename could result
        # "US/Eastern" instead of "America/New_York" as bestzonename,
        # in spite of what the sysadmin had specified in the symlink.
        # (There are many duplicates under tzdir, with the same timezone
        # content appearing as an average of 2-3 different file names.)
        path = ::File.readlink("/etc/localtime")
        bestzonename = path.gsub("#{tzdir}/","")
    else # /etc/localtime is a file, so scan for it under tzdir
        localtime_content = File.read("/etc/localtime")

        Find.find(tzdir) do |path|
            # Only consider files (skip directories or symlinks)
            if !::File.directory?(path) && !::File.symlink?(path)
                # Ignore any file named "posixrules" or "localtime"
                if ::File.basename(path) != "posixrules" && ::File.basename(path) != "localtime"
            	    # Do consider if content exactly matches /etc/localtime.
            	    if localtime_content == File.read(path)
                        tzname = path.gsub("#{tzdir}/","")
            	        if validate_zone(tzname)
            	            if (bestzonename.nil? ||
            		        tzname.length < bestzonename.length ||
            		        (tzname.length == bestzonename.length &&
                                 (tzname <=> bestzonename) < 0)
                               )
            		        bestzonename = tzname
            		    end
            	        end
            	    end
            	end
            end
    	end
    end

    return bestzonename
end

# Function to support select_default_timezone(tzdir), which is
# used in recipes/config_initdb.rb.
def identify_system_timezone(tzdir)
    resultbuf = scan_available_timezones(tzdir)

    if !resultbuf.nil?
        # Ignore Olson's rather silly "Factory" zone; use GMT instead
        if (resultbuf <=> "Factory") == 0
            resultbuf = nil
        end

    else
        # Did not find the timezone.  Fallback to use a GMT zone.  Note that the
        # Olson timezone database names the GMT-offset zones in POSIX style: plus
        # is west of Greenwich.
        testtime = DateTime.now
        std_ofs = testtime.strftime("%:z").split(":")[0].to_i

        resultbuf = [
            "Etc/GMT",
            (-std_ofs > 0) ? "+" : "",
            (-std_ofs).to_s
          ].join('')
    end

    return resultbuf
end

#######
# Function to determine the name of the system's default timezone.
# Used in recipes/config_initdb.rb to set these attributes:
#    node.default['postgresql']['config']['log_timezone']
#    node.default['postgresql']['config']['timezone']
def select_default_timezone(tzdir)

    system_timezone = nil

    # Check TZ environment variable 
    tzname = ENV['TZ']
    if !tzname.nil? && !tzname.empty? && validate_zone(tzname)
        system_timezone = tzname

    else
        # Nope, so try to identify system timezone from /etc/localtime
        tzname = identify_system_timezone(tzdir)
        if validate_zone(tzname)
            system_timezone = tzname
        end
    end

    return system_timezone
end

#######
# Function to determine the name of the system's default timezone.
def get_result_orig(query)
  # query could be a String or an Array of String
  if (query.is_a?(String))
    stdin = query
  else
    stdin = query.join("\n")
  end
  @get_result ||= begin
    cmd = shell_out("cat", :input => stdin)
    cmd.stdout
  end
end

#######
# Function to execute an SQL statement in the template1 database.
#   Input: Query could be a single String or an Array of String.
#   Output: A String with |-separated columns and \n-separated rows.
#           Note an empty output could mean psql couldn't connect.
# This is easiest for 1-field (1-row, 1-col) results, otherwise
# it will be complex to parse the results.
def execute_sql(query)
  # query could be a String or an Array of String
  statement = query.is_a?(String) ? query : query.join("\n")
  @execute_sql ||= begin
    cmd = shell_out("psql -q --tuples-only --no-align -d template1 -f -",
          :user => "postgres",
          :input => statement
    )
    # If psql fails, generally the postgresql service is down.
    # Instead of aborting chef with a fatal error, let's just
    # pass these non-zero exitstatus back as empty cmd.stdout.
    if (cmd.exitstatus() == 0 and !cmd.stderr.empty?)
      # An SQL failure is still a zero exitstatus, but then the
      # stderr explains the error, so let's rais that as fatal.
      Chef::Log.fatal("psql failed executing this SQL statement:\n#{statement}")
      Chef::Log.fatal(cmd.stderr)
      raise "SQL ERROR"
    end
    cmd.stdout.chomp
  end
end

#######
# Function to determine if a standard contrib extension is already installed.
#   Input: Extension name
#   Output: true or false
# Best use as a not_if gate on bash "install-#{pg_ext}-extension" resource.
def extension_already_installed?(pg_ext)
  @extension_already_installed ||= begin
    installed=execute_sql("select 'installed' from pg_extension where extname = '#{pg_ext}';")
    installed =~ /^installed$/
  end
end

#######
# Function to determine type of service notification to activate the new config.
#   Input: node['postgresql']['config'] Attributes
#   Output: :start (if psql fails), :reload (if SIGUP sufficient), :restart (if necessary).
# Best use is template "#{node['postgresql']['dir']}/postgresql.conf" conditional notifies.
def minimize_conf_restarts(config)
  # Since we need to capture added/changed/removed settings,
  # we need a left join between all old and the new settings.
  #
  # We need to know whether any settings require a service restart.
  # Those are the ones indicated by pg_settings.context='postmaster'.
  #
  # Through the left join, null new_settings means no entry in new
  # postgresql.conf file, so there is a coalesce to decide what will
  # happen with new postgresql.conf: either new_settings or boot_val,
  # which is the parameter value assumed at server startup if the
  # parameter is not otherwise set.
  #
  # To determine whether that would be a change from current settings,
  # there are two sources of complexity:
  # (1) Some settings have a magic value to specify auto-tuning, in
  #     which case source='override' and the supposed reset_val
  #     reports the resulting derived value, not the magic value.
  #     In these cases, the boot_val is the magic value, since
  #     the auto-tuning behavior is the postgresql default.
  #     Other source='override' settings, like file locations,
  #     have a null boot_val and the reset_val does convey the
  #     current configuration. When source<>'override', the
  #     reset_val does actually reflect the current configuration.
  # (2) Some integer settings have a unit, which is an implicit
  #     multiplier applied to a value specified as a naked integer.
  #     Or the value may be specified directly in appropriate units
  #     using a suffix such as MB or ms. The naked representation
  #     is always in boot_val/reset_val as explained above. The
  #     most human-readable suffixed representation is generally
  #     available through the current_setting function. This would
  #     be 1GB instead of 1024MB, for example. So if the chef
  #     attribute value is not in simplest form, the match can't be
  #     detected and the service will be restarted (not optimimal,
  #     but not a malfunction). Note that this optimization is also
  #     skipped when source='override' because current_setting will
  #     report the auto-tune value in effect.

  query = [
    "SELECT CASE WHEN count(*) > 0 THEN 'restart ' || array_agg(name)::text",
    "            ELSE 'reload' END AS required_action",
    "  FROM pg_settings",
    "  LEFT JOIN (",
    config.sort.map { |k,v|
             "    (select '#{k}' as key, '#{case v
                                            when String
                                              v
                                            when TrueClass
                                              'on'
                                            when FalseClass
                                              'off'
                                            else
                                              v
                                            end
                                           }' as setting)"
           }.join(" UNION\n"),
    "  ) AS attributes",
    "    ON lower(pg_settings.name) = lower(attributes.key)",
    " WHERE context = 'postmaster'",
    "   AND COALESCE(attributes.setting, boot_val)",
    "         -- Test if that new configuration setting is currently in effect:",
    "       NOT IN (",
    "         -- Ordinary setting, which might be an integer scaled by the unit.",
    "         COALESCE(CASE WHEN source = 'override' THEN boot_val ELSE reset_val END, '-'),",
    "         -- Human readable setting, in a form that also specifies the unit.",
    "         COALESCE(CASE WHEN source = 'override' THEN NULL ELSE current_setting(name) END, '-')",
    "       );"
  ]

  #Chef::Log.warn("CONFIG SQL:\n#{query.join("\n")}")

  @minimize_conf_restarts ||= begin
    case execute_sql(query)
    when /^restart (.*)$/
      Chef::Log.warn("minimize_conf_restarts: must restart service[postgresql] for postgresql.conf changes to %s." % $1)
      :restart
    when 'reload'
      Chef::Log.warn("minimize_conf_restarts: may reload service[postgresql] because no postgresql.conf changes require a restart.")
      :reload
    else
      Chef::Log.warn("minimize_conf_restarts: should start service[postgresql] for postgresql.conf changes because service isn't running.")
      :start
    end
  end
end

# End the Opscode::PostgresqlHelpers module
  end
end
