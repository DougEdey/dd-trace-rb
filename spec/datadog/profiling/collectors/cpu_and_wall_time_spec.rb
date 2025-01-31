# typed: ignore

require 'datadog/profiling/spec_helper'
require 'datadog/profiling/collectors/cpu_and_wall_time'

RSpec.describe Datadog::Profiling::Collectors::CpuAndWallTime do
  before do
    skip_if_profiling_not_supported(self)

    [t1, t2, t3].each { ready_queue.pop }
    expect(Thread.list).to include(Thread.main, t1, t2, t3)
  end

  let(:recorder) { Datadog::Profiling::StackRecorder.new }
  let(:ready_queue) { Queue.new }
  let(:t1) do
    Thread.new(ready_queue) do |ready_queue|
      ready_queue << true
      sleep
    end
  end
  let(:t2) do
    Thread.new(ready_queue) do |ready_queue|
      ready_queue << true
      sleep
    end
  end
  let(:t3) do
    Thread.new(ready_queue) do |ready_queue|
      ready_queue << true
      sleep
    end
  end
  let(:max_frames) { 123 }

  let(:pprof_result) do
    serialization_result = recorder.serialize
    raise 'Unexpected: Serialization failed' unless serialization_result

    serialization_result.last
  end
  let(:samples) { samples_from_pprof(pprof_result) }
  let(:invalid_time) { -1 }

  subject(:cpu_and_wall_time_collector) { described_class.new(recorder: recorder, max_frames: max_frames) }

  after do
    [t1, t2, t3].each do |thread|
      thread.kill
      thread.join
    end
  end

  def sample
    described_class::Testing._native_sample(cpu_and_wall_time_collector)
  end

  def on_gc_start
    described_class::Testing._native_on_gc_start(cpu_and_wall_time_collector)
  end

  def on_gc_finish
    described_class::Testing._native_on_gc_finish(cpu_and_wall_time_collector)
  end

  def sample_after_gc
    described_class::Testing._native_sample_after_gc(cpu_and_wall_time_collector)
  end

  def thread_list
    described_class::Testing._native_thread_list
  end

  def per_thread_context
    described_class::Testing._native_per_thread_context(cpu_and_wall_time_collector)
  end

  def stats
    described_class::Testing._native_stats(cpu_and_wall_time_collector)
  end

  describe '#sample' do
    it 'samples all threads' do
      all_threads = Thread.list

      sample

      expect(Thread.list).to eq(all_threads), 'Threads finished during this spec, causing flakiness!'
      expect(samples.size).to be all_threads.size
    end

    it 'tags the samples with the object ids of the Threads they belong to' do
      sample

      expect(samples.map { |it| it.fetch(:labels).fetch(:'thread id') })
        .to include(*[Thread.main, t1, t2, t3].map(&:object_id).map(&:to_s))
    end

    it 'includes the thread names, if available' do
      skip 'Thread names not available on Ruby 2.2' if RUBY_VERSION < '2.3'

      t1.name = 'thread t1'
      t2.name = nil
      t3.name = 'thread t3'

      sample

      t1_sample = samples.find { |it| it.fetch(:labels).fetch(:'thread id') == t1.object_id.to_s }
      t2_sample = samples.find { |it| it.fetch(:labels).fetch(:'thread id') == t2.object_id.to_s }
      t3_sample = samples.find { |it| it.fetch(:labels).fetch(:'thread id') == t3.object_id.to_s }

      expect(t1_sample).to include(labels: include(:'thread name' => 'thread t1'))
      expect(t2_sample.fetch(:labels).keys).to_not include(:'thread name')
      expect(t3_sample).to include(labels: include(:'thread name' => 'thread t3'))
    end

    it 'does not include thread names on Ruby 2.2' do
      skip 'Testcase only applies to Ruby 2.2' if RUBY_VERSION >= '2.3'

      expect(samples.flat_map { |it| it.fetch(:labels).keys }).to_not include(':thread name')
    end

    it 'includes the wall-time elapsed between samples' do
      sample
      wall_time_at_first_sample =
        per_thread_context.fetch(t1).fetch(:wall_time_at_previous_sample_ns)

      sample
      wall_time_at_second_sample =
        per_thread_context.fetch(t1).fetch(:wall_time_at_previous_sample_ns)

      t1_samples = samples.select { |it| it.fetch(:labels).fetch(:'thread id') == t1.object_id.to_s }
      wall_time = t1_samples.first.fetch(:values).fetch(:'wall-time')

      expect(t1_samples.size)
        .to be(1), "Expected thread t1 to always have same stack trace (because it's sleeping), got #{t1_samples.inspect}"

      expect(wall_time).to be(wall_time_at_second_sample - wall_time_at_first_sample)
    end

    it 'tags samples with how many times they were seen' do
      5.times { sample }

      t1_sample = samples.find { |it| it.fetch(:labels).fetch(:'thread id') == t1.object_id.to_s }

      expect(t1_sample).to include(values: include(:'cpu-samples' => 5))
    end

    [:before, :after].each do |on_gc_finish_order|
      context "when a thread is marked as being in garbage collection, #{on_gc_finish_order} on_gc_finish" do
        # Until sample_after_gc gets called, the state left over by both on_gc_start and on_gc_finish "blocks" time
        # from being assigned to further samples. Note this is expected to be very rare in practice, otherwise we would
        # probably want to look into skipping these samples entirely.
        it 'records the wall-time between a previous sample and the start of garbage collection, and no further time' do
          sample
          wall_time_at_first_sample = per_thread_context.fetch(Thread.current).fetch(:wall_time_at_previous_sample_ns)

          on_gc_start
          on_gc_finish if on_gc_finish_order == :after

          wall_time_at_gc_start = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.wall_time_at_start_ns')

          5.times { sample } # Even though we keep sampling, the result only includes the time until we called on_gc_start

          total_wall_for_rspec_thread =
            samples
              .select { |it| it.fetch(:labels).fetch(:'thread id') == Thread.current.object_id.to_s }
              .map { |it| it.fetch(:values).fetch(:'wall-time') }
              .reduce(:+)

          expect(total_wall_for_rspec_thread).to be(wall_time_at_gc_start - wall_time_at_first_sample)
        end

        # The whole point of wall_time_at_previous_sample_ns is to track the past point in time that we use as start of
        # the time range for a sample.
        # BUT, we can't let it advance during GC as it should only get accounted for when GC finishes.
        it 'does not advance wall_time_at_previous_sample_ns for the thread beyond gc_tracking.wall_time_at_start_ns' do
          sample

          on_gc_start
          on_gc_finish if on_gc_finish_order == :after

          wall_time_at_gc_start = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.wall_time_at_start_ns')

          5.times { sample }

          wall_time_at_previous_sample_ns =
            per_thread_context.fetch(Thread.current).fetch(:wall_time_at_previous_sample_ns)

          expect(wall_time_at_previous_sample_ns).to be wall_time_at_gc_start
        end
      end
    end

    context 'cpu-time behavior' do
      context 'when not on Linux' do
        before do
          skip 'The fallback behavior only applies when not on Linux' if PlatformHelpers.linux?
        end

        it 'sets the cpu-time on every sample to zero' do
          5.times { sample }

          expect(samples).to all include(values: include(:'cpu-time' => 0))
        end
      end

      context 'on Linux' do
        before do
          skip 'Test only runs on Linux' unless PlatformHelpers.linux?
        end

        it 'includes the cpu-time for the samples' do
          rspec_thread_spent_time = Datadog::Core::Utils::Time.measure(:nanosecond) do
            5.times { sample }
            samples # to trigger serialization
          end

          # The only thread we're guaranteed has spent some time on cpu is the rspec thread, so let's check we have
          # some data for it
          total_cpu_for_rspec_thread =
            samples
              .select { |it| it.fetch(:labels).fetch(:'thread id') == Thread.current.object_id.to_s }
              .map { |it| it.fetch(:values).fetch(:'cpu-time') }
              .reduce(:+)

          # The **wall-clock time** spent by the rspec thread is going to be an upper bound for the cpu time spent,
          # e.g. if it took 5 real world seconds to run the test, then at most the rspec thread spent those 5 seconds
          # running on CPU, but possibly it spent slightly less.
          expect(total_cpu_for_rspec_thread).to be_between(1, rspec_thread_spent_time)
        end

        [:before, :after].each do |on_gc_finish_order|
          context "when a thread is marked as being in garbage collection, #{on_gc_finish_order} on_gc_finish" do
            it 'records the cpu-time between a previous sample and the start of garbage collection, and no further time' do
              sample
              cpu_time_at_first_sample = per_thread_context.fetch(Thread.current).fetch(:cpu_time_at_previous_sample_ns)

              on_gc_start
              on_gc_finish if on_gc_finish_order == :after

              cpu_time_at_gc_start = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.cpu_time_at_start_ns')

              # Even though we keep sampling, the result only includes the time until we called on_gc_start
              5.times { sample }

              total_cpu_for_rspec_thread =
                samples
                  .select { |it| it.fetch(:labels).fetch(:'thread id') == Thread.current.object_id.to_s }
                  .map { |it| it.fetch(:values).fetch(:'cpu-time') }
                  .reduce(:+)

              expect(total_cpu_for_rspec_thread).to be(cpu_time_at_gc_start - cpu_time_at_first_sample)
            end

            # The whole point of cpu_time_at_previous_sample_ns is to track the past point in time that we use as start of
            # the time range for a sample.
            # BUT, we can't let it advance during GC as it should only get accounted for when GC finishes.
            it 'does not advance cpu_time_at_previous_sample_ns for the thread beyond gc_tracking.cpu_time_at_start_ns' do
              sample

              on_gc_start
              on_gc_finish if on_gc_finish_order == :after

              cpu_time_at_gc_start = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.cpu_time_at_start_ns')

              5.times { sample }

              cpu_time_at_previous_sample_ns =
                per_thread_context.fetch(Thread.current).fetch(:cpu_time_at_previous_sample_ns)

              expect(cpu_time_at_previous_sample_ns).to be cpu_time_at_gc_start
            end
          end
        end
      end
    end
  end

  describe '#on_gc_start' do
    context 'if a thread has not been sampled before' do
      it "does not record anything in the caller thread's context" do
        on_gc_start

        expect(per_thread_context.keys).to_not include(Thread.current)
      end

      it 'increments the gc_samples_missed_due_to_missing_context stat' do
        expect { on_gc_start }.to change { stats.fetch(:gc_samples_missed_due_to_missing_context) }.from(0).to(1)
      end
    end

    context 'after the first sample' do
      before { sample }

      it "records the wall-time when garbage collection started in the caller thread's context" do
        wall_time_before_on_gc_start_ns = Datadog::Core::Utils::Time.get_time(:nanosecond)
        on_gc_start
        wall_time_after_on_gc_start_ns = Datadog::Core::Utils::Time.get_time(:nanosecond)

        expect(per_thread_context.fetch(Thread.current)).to include(
          :'gc_tracking.wall_time_at_start_ns' =>
            be_between(wall_time_before_on_gc_start_ns, wall_time_after_on_gc_start_ns)
        )
      end

      context 'cpu-time behavior' do
        context 'when not on Linux' do
          before do
            skip 'The fallback behavior only applies when not on Linux' if PlatformHelpers.linux?
          end

          it "records the cpu-time when garbage collection started in the caller thread's context as zero" do
            on_gc_start

            expect(per_thread_context.fetch(Thread.current)).to include(:'gc_tracking.cpu_time_at_start_ns' => 0)
          end
        end

        context 'on Linux' do
          before do
            skip 'Test only runs on Linux' unless PlatformHelpers.linux?
          end

          it "records the cpu-time when garbage collection started in the caller thread's context" do
            on_gc_start

            expect(per_thread_context.fetch(Thread.current)).to include(:'gc_tracking.cpu_time_at_start_ns' => be > 0)
          end
        end
      end

      context 'when called again after on_gc_finish but before sample_after_gc' do
        before do
          on_gc_start
          on_gc_finish
        end

        it 'does not change the gc start times' do
          start_times = proc do
            cpu_time = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.cpu_time_at_start_ns')
            wall_time = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.wall_time_at_start_ns')

            [cpu_time, wall_time]
          end

          expect { on_gc_start }.to_not change(&start_times)
        end
      end
    end
  end

  describe '#on_gc_finish' do
    context 'when thread has not been sampled before' do
      it "does not record anything in the caller thread's context" do
        on_gc_start

        expect(per_thread_context.keys).to_not include(Thread.current)
      end
    end

    context 'when thread has been sampled before' do
      before { sample }

      context 'when on_gc_start was not called before' do
        # See comment in the actual implementation on when/why this can happen

        it 'does not change the gc finish times' do
          on_gc_finish

          expect(per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.cpu_time_at_finish_ns')).to be invalid_time
          expect(per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.wall_time_at_finish_ns')).to be invalid_time
        end
      end

      context 'when on_gc_start was previously called' do
        before { on_gc_start }

        it "records the wall-time when garbage collection finished in the caller thread's context" do
          wall_time_before_on_gc_finish_ns = Datadog::Core::Utils::Time.get_time(:nanosecond)
          on_gc_finish
          wall_time_after_on_gc_finish_ns = Datadog::Core::Utils::Time.get_time(:nanosecond)

          expect(per_thread_context.fetch(Thread.current)).to include(
            :'gc_tracking.wall_time_at_finish_ns' =>
              be_between(wall_time_before_on_gc_finish_ns, wall_time_after_on_gc_finish_ns)
          )
        end

        context 'cpu-time behavior' do
          context 'when not on Linux' do
            before do
              skip 'The fallback behavior only applies when not on Linux' if PlatformHelpers.linux?
            end

            it "records the cpu-time when garbage collection finished in the caller thread's context as zero" do
              on_gc_finish

              expect(per_thread_context.fetch(Thread.current)).to include(:'gc_tracking.cpu_time_at_finish_ns' => 0)
            end
          end

          context 'on Linux' do
            before do
              skip 'Test only runs on Linux' unless PlatformHelpers.linux?
            end

            it "records the cpu-time when garbage collection finished in the caller thread's context" do
              on_gc_finish

              expect(per_thread_context.fetch(Thread.current)).to include(:'gc_tracking.cpu_time_at_finish_ns' => be > 0)
            end
          end
        end
      end

      context 'when going through multiple cycles of on_gc_start/on_gc_finish without sample_after_gc getting called' do
        it 'keeps the cpu-time and wall-time at finish from the LAST on_gc_finish' do
          context_tracking = []

          5.times do
            on_gc_start
            on_gc_finish

            context_tracking << per_thread_context.fetch(Thread.current)
          end

          cpu_time_from_last_on_gc_finish = context_tracking.last.fetch(:'gc_tracking.cpu_time_at_finish_ns')
          wall_time_from_last_on_gc_finish = context_tracking.last.fetch(:'gc_tracking.wall_time_at_finish_ns')

          expect(context_tracking.first)
            .to include(:'gc_tracking.wall_time_at_finish_ns' => be < wall_time_from_last_on_gc_finish)

          # This always advances: all_but_last <= the last one
          # (Needs the <= because unfortunately we may not get enough precision, otherwise it would be <)
          all_but_last = context_tracking[0..-2]
          expect(
            all_but_last.map { |it| it.fetch(:'gc_tracking.cpu_time_at_finish_ns') }
          ).to all be <= cpu_time_from_last_on_gc_finish
          expect(
            all_but_last.map { |it| it.fetch(:'gc_tracking.wall_time_at_finish_ns') }
          ).to all be <= wall_time_from_last_on_gc_finish
        end
      end
    end
  end

  describe '#sample_after_gc' do
    let(:gc_samples) { samples.select { |it| it.fetch(:locations).first.fetch(:path) == 'Garbage Collection' } }

    before { sample }

    context 'when there is no thread with gc time to be sampled' do
      it 'does not sample any threads' do
        sample_after_gc

        expect(gc_samples).to be_empty
      end

      it 'does not increment the gc_samples stat' do
        sample_after_gc

        expect(stats.fetch(:gc_samples)).to be 0
      end
    end

    context 'when there is a thread with gc start time but no finish time' do
      before { on_gc_start }

      it 'does not sample any threads' do
        sample_after_gc

        expect(gc_samples).to be_empty
      end

      it 'does not increment the gc_samples stat' do
        sample_after_gc

        expect(stats.fetch(:gc_samples)).to be 0
      end
    end

    context 'when there is a thread with a recorded gc start and finish time' do
      let(:gc_sample) do
        expect(gc_samples.size).to be 1
        gc_samples.first
      end

      before do
        on_gc_start
        on_gc_finish
      end

      it 'samples the thread with recorded gc start and finish time, marking it as being in Garbage Collection' do
        sample_after_gc

        expect(gc_sample.fetch(:labels).fetch(:'thread id')).to eq Thread.current.object_id.to_s
      end

      it 'samples the thread with recorded gc start and finish time, recording the times between gc start and finish' do
        cpu_time_at_start_ns = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.cpu_time_at_start_ns')
        cpu_time_at_finish_ns = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.cpu_time_at_finish_ns')
        wall_time_at_start_ns = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.wall_time_at_start_ns')
        wall_time_at_finish_ns = per_thread_context.fetch(Thread.current).fetch(:'gc_tracking.wall_time_at_finish_ns')

        sample_after_gc

        expect(gc_sample.fetch(:values)).to include(
          :"cpu-samples" => 1,
          :'cpu-time' => cpu_time_at_finish_ns - cpu_time_at_start_ns,
          :"wall-time" => wall_time_at_finish_ns - wall_time_at_start_ns,
        )
      end

      it 'resets the gc tracking fields back to invalid_time' do
        sample_after_gc

        expect(per_thread_context.fetch(Thread.current)).to include(
          :'gc_tracking.cpu_time_at_start_ns' => invalid_time,
          :'gc_tracking.cpu_time_at_finish_ns' => invalid_time,
          :'gc_tracking.wall_time_at_start_ns' => invalid_time,
          :'gc_tracking.wall_time_at_finish_ns' => invalid_time,
        )
      end

      it 'increments the gc_samples stat' do
        expect { sample_after_gc }.to change { stats.fetch(:gc_samples) }.from(0).to(1)
      end

      it 'does not sample any other threads' do
        sample_after_gc

        expect(gc_samples.size).to be 1
      end

      it 'advances the wall_time_at_previous_sample_ns for the sampled thread by the time spent in garbage collection' do
        wall_time_at_previous_sample_ns_before =
          per_thread_context.fetch(Thread.current).fetch(:wall_time_at_previous_sample_ns)

        sample_after_gc

        wall_time_spent_in_gc = gc_sample.fetch(:values).fetch(:'wall-time')

        expect(per_thread_context.fetch(Thread.current)).to include(
          wall_time_at_previous_sample_ns: wall_time_at_previous_sample_ns_before + wall_time_spent_in_gc
        )
      end

      context 'cpu-time behavior' do
        context 'when not on Linux' do
          before do
            skip 'The fallback behavior only applies when not on Linux' if PlatformHelpers.linux?
          end

          it 'keeps the cpu_time_at_previous_sample_ns as invalid_time' do
            sample_after_gc

            expect(per_thread_context.fetch(Thread.current)).to include(cpu_time_at_previous_sample_ns: invalid_time)
          end
        end

        context 'on Linux' do
          before do
            skip 'Test only runs on Linux' unless PlatformHelpers.linux?
          end

          it 'advances the cpu_time_at_previous_sample_ns for the sampled thread by the time spent in garbage collection' do
            cpu_time_at_previous_sample_ns_before =
              per_thread_context.fetch(Thread.current).fetch(:cpu_time_at_previous_sample_ns)

            sample_after_gc

            cpu_time_spent_in_gc = gc_sample.fetch(:values).fetch(:'cpu-time')

            expect(per_thread_context.fetch(Thread.current)).to include(
              cpu_time_at_previous_sample_ns: cpu_time_at_previous_sample_ns_before + cpu_time_spent_in_gc
            )
          end
        end
      end
    end
  end

  describe '#thread_list' do
    it "returns the same as Ruby's Thread.list" do
      expect(thread_list).to eq Thread.list
    end
  end

  describe '#per_thread_context' do
    context 'before sampling' do
      it do
        expect(per_thread_context).to be_empty
      end
    end

    context 'after sampling' do
      before do
        @wall_time_before_sample_ns = Datadog::Core::Utils::Time.get_time(:nanosecond)
        sample
        @wall_time_after_sample_ns = Datadog::Core::Utils::Time.get_time(:nanosecond)
      end

      it 'contains all the sampled threads' do
        expect(per_thread_context.keys).to include(Thread.main, t1, t2, t3)
      end

      it 'contains the thread ids (object_ids) of all sampled threads' do
        per_thread_context.each do |thread, context|
          expect(context.fetch(:thread_id)).to eq thread.object_id.to_s
        end
      end

      it 'sets the wall_time_at_previous_sample_ns to the current wall clock value' do
        expect(per_thread_context.values).to all(
          include(wall_time_at_previous_sample_ns: be_between(@wall_time_before_sample_ns, @wall_time_after_sample_ns))
        )
      end

      context 'cpu time behavior' do
        context 'when not on Linux' do
          before do
            skip 'The fallback behavior only applies when not on Linux' if PlatformHelpers.linux?
          end

          it 'sets the cpu_time_at_previous_sample_ns to zero' do
            expect(per_thread_context.values).to all(
              include(cpu_time_at_previous_sample_ns: 0)
            )
          end

          it 'marks the thread_cpu_time_ids as not valid' do
            expect(per_thread_context.values).to all(
              include(thread_cpu_time_id_valid?: false)
            )
          end
        end

        context 'on Linux' do
          before do
            skip 'Test only runs on Linux' unless PlatformHelpers.linux?
          end

          it 'sets the cpu_time_at_previous_sample_ns to the current cpu clock value' do
            # It's somewhat difficult to validate the actual value since this is an operating system-specific value
            # which should only be assessed in relation to other values for the same thread, not in absolute
            expect(per_thread_context.values).to all(
              include(cpu_time_at_previous_sample_ns: not_be(0))
            )
          end

          it 'returns a bigger value for each sample' do
            sample_values = []

            3.times do
              sample

              sample_values <<
                per_thread_context[Thread.main].fetch(:cpu_time_at_previous_sample_ns)
            end

            expect(sample_values.uniq.size).to be(3), 'Every sample is expected to have a differ cpu time value'
            expect(sample_values).to eq(sample_values.sort), 'Samples are expected to be in ascending order'
          end

          it 'marks the thread_cpu_time_ids as valid' do
            expect(per_thread_context.values).to all(
              include(thread_cpu_time_id_valid?: true)
            )
          end
        end
      end
    end

    context 'after sampling multiple times' do
      it 'contains only the threads still alive' do
        sample

        # All alive threads still in there
        expect(per_thread_context.keys).to include(Thread.main, t1, t2, t3)

        # Get rid of t2
        t2.kill
        t2.join

        # Currently the clean-up gets triggered only every 100th sample, so we need to do this to trigger the
        # clean-up. This can probably be improved (see TODO on the actual implementation)
        100.times { sample }

        expect(per_thread_context.keys).to_not include(t2)
        expect(per_thread_context.keys).to include(Thread.main, t1, t3)
      end
    end
  end
end
