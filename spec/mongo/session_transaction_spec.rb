require 'spec_helper'

class SessionTransactionSpecError < StandardError; end

describe Mongo::Session do
  min_server_fcv '4.0'
  require_topology :replica_set, :sharded

  let(:session) do
    authorized_client.start_session(session_options)
  end

  let(:session_options) do
    {}
  end

  let(:collection) do
    authorized_client['session-transaction-test']
  end

  before do
    collection.delete_many
  end

  describe '#with_transaction' do
    context 'callback successful' do
      it 'commits' do
        session.with_transaction do
          collection.insert_one(a: 1)
        end

        result = collection.find(a: 1).first
        expect(result[:a]).to eq(1)
      end

      it 'propagates callback\'s return value' do
        rv = session.with_transaction do
          42
        end
        expect(rv).to eq(42)
      end
    end

    context 'callback raises' do
      it 'propagates the exception' do
        expect do
          session.with_transaction do
            raise SessionTransactionSpecError, 'test error'
          end
        end.to raise_error(SessionTransactionSpecError, 'test error')
      end
    end

    context 'callback aborts transaction' do
      it 'does not raise exceptions and propagates callback\'s return value' do
        rv = session.with_transaction do
          session.abort_transaction
          42
        end
        expect(rv).to eq(42)
      end
    end

    context 'timeout with callback raising TransientTransactionError' do
      max_example_run_time 7

      after do
        Timecop.return
      end

      it 'times out' do
        warp = Time.now + 200
        entered = false

        Thread.new do
          until entered
            sleep 0.1
          end
          Timecop.travel warp
        end

        expect do
          session.with_transaction do
            entered = true

            # This sleep is to give the interrupting thread a chance to run,
            # it significantly affects how much time is burned in this
            # looping thread
            sleep 0.1

            exc = Mongo::Error::OperationFailure.new('timeout test')
            exc.send(:add_label, Mongo::Error::TRANSIENT_TRANSACTION_ERROR_LABEL)
            raise exc
          end
        end.to raise_error(Mongo::Error::OperationFailure, 'timeout test')
      end
    end

    %w(UNKNOWN_TRANSACTION_COMMIT_RESULT_LABEL TRANSIENT_TRANSACTION_ERROR_LABEL).each do |label|
      context "timeout with commit raising with #{label}" do
        max_example_run_time 7

        after do
          Timecop.return
        end

        before do
          # create collection if it does not exist
          collection.insert_one(a: 1)
        end

        it 'times out' do
          warp = Time.now + 200
          entered = false

          Thread.new do
            until entered
              sleep 0.1
            end
            Timecop.travel warp
          end

          exc = Mongo::Error::OperationFailure.new('timeout test')
          exc.send(:add_label, Mongo::Error.const_get(label))

          expect(session).to receive(:commit_transaction).and_raise(exc).at_least(:once)

          expect do
            session.with_transaction do
              entered = true

              # This sleep is to give the interrupting thread a chance to run,
              # it significantly affects how much time is burned in this
              # looping thread
              sleep 0.1

              collection.insert_one(a: 2)
            end
          end.to raise_error(Mongo::Error::OperationFailure, 'timeout test')
        end
      end
    end
  end
end
